# CLAM-WIT: name=NeuroIntegration
# CLAM-WIT: version=1.0.0
# CLAM-WIT: about=Bidirectional LLM <-> world model integration — context injection, validation, knowledge extraction
# CLAM-WIT: usage=Auto-runs on context/message_end/agent_end bus events. Three phases: inject facts, validate output, extract knowledge.
# CLAM-WIT: hint=neurosymbolic, world model, context injection, validation, knowledge extraction
# CLAM-WIT: author=CLAM
# CLAM-WIT: license=Artistic-2.0
#
# Phase 1: LLM reads world model (inject relevant facts into context)
# Phase 2: Rules validate LLM output (catch contradictions)
# Phase 3: LLM updates world model (extract knowledge from conversation)
package AI::Clam::Wits::Neuro::NeuroIntegration;
use strict;
use warnings;
use AI::Clam::Util qw(jencode jdecode);

sub new {
    my ($class, %args) = @_;
    return bless {
        world_model => $args{world_model},
        rules       => $args{rules},
        provider    => $args{provider},
        tracer      => $args{tracer},
        metrics     => $args{metrics},
        max_facts   => $args{max_facts} // 20,
        validate    => $args{validate} // 1,
        extract     => $args{extract}  // 1,
    }, $class;
}

sub register {
    my ($self, $api) = @_;
    $self->{api} = $api;

    # Lazily create WorldModel from same store.
    unless ($self->{world_model}) {
        eval {
            require AI::Clam::WorldModel;
            $self->{world_model} = AI::Clam::WorldModel->new(store => $api->store);
        };
    }

    # Subscribe to all three phases.
    $api->on('context',     sub { $self->_on_context(@_) });
    $api->on('message_end', sub { $self->_on_message_end(@_) });
    $api->on('agent_end',   sub { $self->_on_agent_end(@_) });

    return $self;
}

# === PHASE 1: LLM reads world model ===

sub _on_context {
    my ($self, $ev) = @_;
    return unless $self->{world_model};

    my $trace_id;
    $trace_id = $self->{tracer}->start_span('neuro.context_inject', topic => 'neuro')
        if $self->{tracer};

    my $messages = $ev->{payload}{messages} // [];
    my $query = _extract_query($messages);
    return unless length $query;

    my @facts;
    my @keywords = grep { length($_) > 2 } split /\s+/, lc($query);
    my %seen_entities;
    my @all_entities;

    for my $keyword (@keywords) {
        my $entities = $self->{world_model}->search_entities($keyword, limit => $self->{max_facts});
        for my $ent (@$entities) {
            next if $seen_entities{$ent->{id}}++;
            push @all_entities, $ent;
            my $attrs = ref $ent->{attributes} eq 'HASH' ? $ent->{attributes} : {};
            push @facts, sprintf("- %s (%s): %s",
                $ent->{name} // $ent->{id},
                $ent->{type},
                join(', ', map { "$_=$attrs->{$_}" } sort keys %$attrs));
        }
    }

    my @top_entities = @all_entities[0..($#all_entities < 4 ? $#all_entities : 4)];
    for my $ent (@top_entities) {
        my $facts = $self->{world_model}->query_facts(entity_id => $ent->{id});
        for my $f (@$facts) {
            push @facts, sprintf("- %s: %s (confidence: %.0f%%)",
                $f->{predicate}, $f->{value} // '', ($f->{confidence} // 1) * 100);
        }
    }

    return unless @facts;

    my $context = "Known facts from world model:\n" . join("\n", @facts);
    $self->{metrics}->inc('neuro.context_injected') if $self->{metrics};

    if ($self->{tracer} && defined $trace_id) {
        $self->{tracer}->end_span($trace_id);
    }

    return { message => $context };
}

# === PHASE 2: Rules validate LLM output ===

sub _on_message_end {
    my ($self, $ev) = @_;
    return unless $self->{validate} && $self->{world_model};

    my $content = $ev->{payload}{content}{text} // '';
    return unless length $content;

    my $trace_id;
    $trace_id = $self->{tracer}->start_span('neuro.validate_output', topic => 'neuro')
        if $self->{tracer};

    my @violations = $self->_validate_output($content);
    $self->{metrics}->inc('neuro.validations') if $self->{metrics};

    if (@violations) {
        $self->{metrics}->inc('neuro.violations') if $self->{metrics};
        if ($self->{tracer} && defined $trace_id) {
            $self->{tracer}->end_span($trace_id);
        }
        return {
            role    => 'assistant',
            content => {
                text       => $content,
                tool_calls => [],
                _violations => \@violations,
            },
        };
    }

    if ($self->{tracer} && defined $trace_id) {
        $self->{tracer}->end_span($trace_id);
    }
    return undef;
}

sub _validate_output {
    my ($self, $output) = @_;
    my @violations;
    my $facts = $self->{world_model}->query_facts();
    for my $fact (@$facts) {
        my $predicate = lc($fact->{predicate} // '');
        my $value = lc($fact->{value} // '');
        next unless length $predicate && length $value;
        if ($output =~ /(?:is not|isn't|are not|aren't|was not|wasn't)\s+\Q$value\E/i) {
            push @violations, {
                type    => 'contradiction',
                fact    => "$predicate: $value",
                message => "Output contradicts known fact: $predicate is $value",
            };
        }
        if ($output =~ /(?:never|no longer)\s+\Q$value\E/i) {
            push @violations, {
                type    => 'negation',
                fact    => "$predicate: $value",
                message => "Output negates known fact: $predicate is $value",
            };
        }
    }
    return @violations;
}

# === PHASE 3: LLM updates world model ===

sub _on_agent_end {
    my ($self, $ev) = @_;
    return unless $self->{extract} && $self->{world_model};

    my $trace_id;
    $trace_id = $self->{tracer}->start_span('neuro.extract_knowledge', topic => 'neuro')
        if $self->{tracer};

    my $session_id = $ev->{payload}{session_id};
    return unless $session_id;

    my $store = $self->{api}->store;
    my $messages = $store->message_path($session_id);
    return unless @$messages;

    my $conversation = join("\n", map {
        my $content = ref $_->{content} eq 'HASH'
            ? ($_->{content}{text} // '')
            : ($_->{content} // '');
        sprintf("[%s] %s", $_->{role}, $content);
    } @$messages);

    my @entities = _extract_entities($conversation);
    my @facts = _extract_facts($conversation);

    my $added = 0;
    for my $ent (@entities) {
        eval {
            $self->{world_model}->add_entity(
                type       => $ent->{type},
                name       => $ent->{name},
                attributes => $ent->{attrs} // {},
            );
            $added++;
        };
    }

    for my $fact (@facts) {
        eval {
            $self->{world_model}->assert_fact(
                entity_id  => $fact->{entity_id},
                predicate  => $fact->{predicate},
                value      => $fact->{value},
                source     => 'llm_extraction',
                confidence => $fact->{confidence} // 0.7,
            );
            $added++;
        };
    }

    $self->{metrics}->inc('neuro.extracted', $added) if $self->{metrics} && $added;

    if ($self->{tracer} && defined $trace_id) {
        $self->{tracer}->end_span($trace_id);
    }

    return undef;
}

# === HELPERS ===

sub _extract_query {
    my ($messages) = @_;
    for my $m (reverse @$messages) {
        next unless ($m->{role} // '') eq 'user';
        my $text = ref $m->{content} eq 'HASH'
            ? ($m->{content}{text} // '')
            : ($m->{content} // '');
        return $text if length $text;
    }
    return '';
}

sub _extract_entities {
    my ($text) = @_;
    my %seen;
    my @entities;
    while ($text =~ /\b([A-Z][a-z]+(?:\s+[A-Z][a-z]+)*)\b/g) {
        my $name = $1;
        next if $seen{$name}++;
        next if length($name) < 2;
        next if $name =~ /^(The|This|That|When|Where|How|What|Why|Yes|No|And|But|Or|For|Not|You|Can|Will|All|Any|Get|Set|Add|Run|See|Put|Try|Use|Make|Take|Give|Let|One|Two|Six|Ten|New|Old|Big|Far|Low|Our|Its|His|Her|My|Your|Our|Their|Its)$/;
        push @entities, { name => $name, type => 'concept', attrs => {} };
    }
    return @entities;
}

sub _extract_facts {
    my ($text) = @_;
    my @facts;
    while ($text =~ /\b(\w+)\s+is\s+(.+?)(?:\.|,|\n|$)/gi) {
        push @facts, { predicate => 'is', value => "$1 is $2", confidence => 0.6 };
    }
    while ($text =~ /\b(\w+)\s+has\s+(.+?)(?:\.|,|\n|$)/gi) {
        push @facts, { predicate => 'has', value => "$1 has $2", confidence => 0.6 };
    }
    return @facts;
}

1;
