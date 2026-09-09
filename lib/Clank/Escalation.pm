# Clank::Escalation — cheapest correct tool first.
#
# Before calling the LLM, check if a crystallized rule, world model fact,
# or rules engine derivation can answer the question. Escalate only when
# cheaper paths fail.
#
# Escalation paths (cheapest first):
#   1. Crystallized rules — regex match on stored rules (~1ms)
#   2. World model facts — FTS5 search over entities/facts (~5ms)
#   3. Rules engine — pattern matching (~10ms)
#   4. LLM fallback — expensive (~500ms, $0.01+)
#
# When the LLM does answer, crystallize the result for next time.
package Clank::Escalation;
use strict;
use warnings;
use Clank::Util qw(now_ms);

sub new {
    my ($class, %args) = @_;
    return bless {
        store       => $args{store},
        bus         => $args{bus},
        provider    => $args{provider},
        metrics     => $args{metrics},
        tracer      => $args{tracer},
        crystallizer => $args{crystallizer},
        world_model  => $args{world_model},
        engine       => $args{engine},
        min_confidence => $args{min_confidence} // 0.6,
    }, $class;
}

sub register {
    my ($self, $api) = @_;
    $self->{api} = $api;

    # Lazily create components from the store.
    $self->{store} //= $api->store;

    unless ($self->{crystallizer}) {
        eval {
            require Clank::Crystallizer;
            $self->{crystallizer} = Clank::Crystallizer->new(store => $self->{store});
        };
    }

    unless ($self->{world_model}) {
        eval {
            require Clank::WorldModel;
            $self->{world_model} = Clank::WorldModel->new(store => $self->{store});
        };
    }

    # Subscribe to escalation check.
    $api->on('escalation.check', sub { $self->_on_check(@_) });

    return $self;
}

# Main escalation check. Returns { handled => 1, output => '...' } or undef.
sub _on_check {
    my ($self, $ev) = @_;
    my $prompt = $ev->{payload}{prompt} // '';
    return undef unless length $prompt;

    my $trace_id;
    $trace_id = $self->{tracer}->start_span('escalation.check', topic => 'escalation')
        if $self->{tracer};

    # Path 1: crystallized rules (cheapest)
    my $result = $self->_check_crystallized($prompt);
    if ($result) {
        $self->{metrics}->inc('escalation.rule_hit') if $self->{metrics};
        $self->{tracer}->end_span($trace_id, { path => 'crystallized' })
            if $self->{tracer} && defined $trace_id;
        return { handled => 1, output => $result, source => 'crystallized_rule' };
    }

    # Path 2: world model facts
    $result = $self->_check_world_model($prompt);
    if ($result) {
        $self->{metrics}->inc('escalation.wm_hit') if $self->{metrics};
        $self->{tracer}->end_span($trace_id, { path => 'world_model' })
            if $self->{tracer} && defined $trace_id;
        return { handled => 1, output => $result, source => 'world_model' };
    }

    # Path 3: rules engine
    $result = $self->_check_rules_engine($prompt);
    if ($result) {
        $self->{metrics}->inc('escalation.engine_hit') if $self->{metrics};
        $self->{tracer}->end_span($trace_id, { path => 'rules_engine' })
            if $self->{tracer} && defined $trace_id;
        return { handled => 1, output => $result, source => 'rules_engine' };
    }

    # No escalation path matched — LLM will be called.
    $self->{metrics}->inc('escalation.llm_fallback') if $self->{metrics};
    $self->{tracer}->end_span($trace_id, { path => 'llm_fallback' })
        if $self->{tracer} && defined $trace_id;
    return undef;
}

# --- Path 1: Crystallized rules ---

sub _check_crystallized {
    my ($self, $prompt) = @_;
    return undef unless $self->{crystallizer};

    my $rules = $self->{crystallizer}->list_rules(limit => 50);
    return undef unless @$rules;

    my @words = grep { length($_) > 3 } split /\W+/, lc($prompt);

    for my $rule (@$rules) {
        my $text = join(' ', $rule->{name} // '', $rule->{condition_def} // '', $rule->{action_def} // '');
        my $matched = 0;
        for my $w (@words) {
            if ($text =~ /\Q$w\E/i) {
                $matched = 1;
                last;
            }
        }
        next unless $matched;

        # Try to compile the condition as a regex and test it.
        my $condition = $rule->{condition_def} // '';
        if (length $condition && $condition !~ /^\s*\{/) {
            # Looks like a plain string/regex, not JSON.
            my $re = eval { qr/$condition/i };
            if ($re && $prompt =~ /$re/) {
                # Try to execute the action.
                my $action = $rule->{action_def} // '';
                if (length $action && $action !~ /^\s*\{/) {
                    # Plain string action — return it directly.
                    $self->{crystallizer}->mark_used($rule->{name});
                    return $action;
                }
            }
        }

        # Try JSON action (fact assertion).
        if ($rule->{action_def} && $rule->{action_def} =~ /^\s*\{/) {
            my $data = eval { Clank::Util::jdecode($rule->{action_def}) };
            if ($data && defined $data->{value}) {
                $self->{crystallizer}->mark_used($rule->{name});
                return $data->{value};
            }
        }
    }

    return undef;
}

# --- Path 2: World model facts ---

sub _check_world_model {
    my ($self, $prompt) = @_;
    return undef unless $self->{world_model};

    my @keywords = grep { length($_) > 2 } split /\W+/, lc($prompt);
    return undef unless @keywords;

    my @all_facts;
    for my $keyword (@keywords) {
        my $entities = $self->{world_model}->search_entities($keyword, limit => 5);
        for my $ent (@$entities) {
            my $attrs = ref $ent->{attributes} eq 'HASH' ? $ent->{attributes} : {};
            my $summary = sprintf("%s (%s): %s",
                $ent->{name} // $ent->{id},
                $ent->{type},
                join(', ', map { "$_=$attrs->{$_}" } sort keys %$attrs));
            push @all_facts, $summary;
        }
    }

    return undef unless @all_facts;

    # Return the top facts as a concise answer.
    my $answer = join("\n", @all_facts[0 .. ($#all_facts > 2 ? 2 : $#all_facts)]);
    return $answer;
}

# --- Path 3: Rules engine ---

sub _check_rules_engine {
    my ($self, $prompt) = @_;
    return undef unless $self->{engine};

    my $result = eval { $self->{engine}->execute({ text => $prompt }) };
    return undef unless defined $result;

    if (ref $result eq 'HASH') {
        return $result->{value} // $result->{text} // undef;
    }
    return "$result" if length "$result";
    return undef;
}

# --- Crystallize LLM results for next time ---

sub crystallize_result {
    my ($self, $prompt, $response) = @_;
    return 0 unless $self->{crystallizer};
    return 0 unless defined $prompt && length $prompt;
    return 0 unless defined $response && length $response;

    my $conversation = [
        { role => 'user', content => $prompt },
        { role => 'assistant', content => $response },
    ];

    my $registered = $self->{crystallizer}->crystallize(
        conversation => $conversation,
    );

    $self->{metrics}->inc('escalation.crystallized', $registered)
        if $self->{metrics} && $registered;

    return $registered;
}

1;
