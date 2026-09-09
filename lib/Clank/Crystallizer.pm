# CLANK-WIT: name=Crystallizer
# CLANK-WIT: version=1.0.0
# CLANK-WIT: about=Capture LLM solutions as deterministic rules — system gets cheaper with use
# CLANK-WIT: usage=Auto-crystallizes on agent_end bus event. Heuristic extraction by default; LLM extraction when provider available.
# CLANK-WIT: hint=crystallization, rules, LLM solutions, deterministic, learning
# CLANK-WIT: author=Clank
# CLANK-WIT: license=Artistic-2.0
#
# Pipeline: conversation → pattern extraction → validate → register rule.
# Hooks into agent_end to analyze completed conversations.
package Clank::Crystallizer;
use strict;
use warnings;
use Clank::Util qw(now_ms jencode jdecode);
use Clank::Rules::Rule ();

sub new {
    my ($class, %args) = @_;
    my $self = bless {
        store       => $args{store},
        provider    => $args{provider},
        world_model => $args{world_model},
        engine      => $args{engine},
        tracer      => $args{tracer},
        metrics     => $args{metrics},
        enabled     => $args{enabled} // 1,
        min_confidence => $args{min_confidence} // 0.6,
    }, $class;
    $self->_init_schema if $self->{store};
    return $self;
}

sub register {
    my ($self, $api) = @_;
    $self->{api} = $api;

    # Use store from API if not provided.
    $self->{store} //= $api->store;

    # Lazily create WorldModel from same store.
    unless ($self->{world_model}) {
        eval {
            require Clank::WorldModel;
            $self->{world_model} = Clank::WorldModel->new(store => $api->store);
        };
    }

    $self->_init_schema;

    # Subscribe to agent_end for post-conversation crystallization.
    $api->on('agent_end', sub { $self->_on_agent_end(@_) });

    # Subscribe to context.knowledge_request to provide crystallized rules.
    $api->on('context.knowledge_request', sub { $self->_on_knowledge_request(@_) });

    return $self;
}

sub _on_knowledge_request {
    my ($self, $ev) = @_;
    my $prompt = $ev->{payload}{prompt} // '';
    return unless length $prompt;

    my @rules;
    my $all_rules = $self->list_rules(limit => 20);
    for my $rule (@$all_rules) {
        # Simple keyword matching: check if rule name or condition matches prompt.
        my $match = 0;
        my $text = join(' ', $rule->{name} // '', $rule->{condition_def} // '', $rule->{action_def} // '');
        my @words = split /\W+/, lc($prompt);
        for my $w (@words) {
            next unless length($w) > 2;
            if ($text =~ /\Q$w\E/i) {
                $match = 1;
                last;
            }
        }
        if ($match) {
            push @rules, {
                type  => 'crystallized_rule',
                text  => sprintf("Rule: %s (confidence: %.0f%%, used %d times): %s",
                    $rule->{name}, ($rule->{confidence} // 1) * 100,
                    $rule->{use_count} // 0, $rule->{action_def}),
            };
        }
    }

    return { rules => \@rules } if @rules;
    return undef;
}

sub _dbh { $_[0]->{store}->dbh }

sub _init_schema {
    my ($self) = @_;
    $self->_dbh->do(qq{
CREATE TABLE IF NOT EXISTS crystallized_rules (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  rule_type TEXT NOT NULL DEFAULT 'pattern',
  condition_def TEXT NOT NULL,
  action_def TEXT NOT NULL,
  confidence REAL DEFAULT 1.0,
  source TEXT DEFAULT 'crystallized',
  session_id TEXT,
  created_at INTEGER,
  last_used INTEGER,
  use_count INTEGER DEFAULT 0,
  disabled INTEGER DEFAULT 0
)});
    $self->_dbh->do(qq{
CREATE INDEX IF NOT EXISTS idx_crystallized_name ON crystallized_rules(name)});
}

# === PUBLIC API ===

sub crystallize {
    my ($self, %args) = @_;
    my $session_id = $args{session_id};
    my $conversation = $args{conversation};

    return 0 unless $self->{enabled};

    my $trace_id;
    $trace_id = $self->{tracer}->start_span('crystallize', topic => 'crystallize')
        if $self->{tracer};

    if (ref $conversation eq 'ARRAY') {
        $conversation = join("\n", map {
            my $c = ref $_->{content} eq 'HASH' ? ($_->{content}{text} // '') : ($_->{content} // '');
            sprintf("[%s] %s", $_->{role}, $c);
        } @$conversation);
    }
    return 0 unless defined $conversation && length $conversation;

    my @patterns = $self->_extract_patterns($conversation);
    return 0 unless @patterns;

    my $registered = 0;
    for my $pattern (@patterns) {
        next unless $pattern->{confidence} >= $self->{min_confidence};
        next unless $self->_validate_pattern($pattern);

        my $id = $self->_store_rule($pattern, session_id => $session_id);
        if ($id) {
            $self->_register_rule($pattern) if $self->{engine};
            $registered++;
        }
    }

    $self->{metrics}->inc('crystallized', $registered) if $self->{metrics};

    if ($self->{tracer} && defined $trace_id) {
        $self->{tracer}->end_span($trace_id);
    }

    return $registered;
}

sub list_rules {
    my ($self, %args) = @_;
    my $disabled = $args{disabled} // 0;
    my $limit = $args{limit} // 100;
    my ($sql, @bind) = ('SELECT * FROM crystallized_rules WHERE disabled = ?', $disabled);
    $sql .= ' ORDER BY confidence DESC, use_count DESC LIMIT ?';
    push @bind, $limit;
    return $self->_dbh->selectall_arrayref($sql, { Slice => {} }, @bind);
}

sub get_rule {
    my ($self, $name) = @_;
    return $self->_dbh->selectrow_hashref(
        'SELECT * FROM crystallized_rules WHERE name = ? AND disabled = 0',
        undef, $name);
}

sub mark_used {
    my ($self, $name) = @_;
    my $now = now_ms();
    $self->_dbh->do(
        'UPDATE crystallized_rules SET use_count = use_count + 1, last_used = ? WHERE name = ?',
        undef, $now, $name);
}

sub disable_rule {
    my ($self, $name) = @_;
    $self->_dbh->do(
        'UPDATE crystallized_rules SET disabled = 1 WHERE name = ?', undef, $name);
    $self->{engine}->remove($name) if $self->{engine};
}

sub stats {
    my ($self) = @_;
    my $dbh = $self->_dbh;
    return {
        total_rules  => $dbh->selectrow_array('SELECT COUNT(*) FROM crystallized_rules'),
        active       => $dbh->selectrow_array('SELECT COUNT(*) FROM crystallized_rules WHERE disabled = 0'),
        total_uses   => $dbh->selectrow_array('SELECT COALESCE(SUM(use_count), 0) FROM crystallized_rules'),
        avg_confidence => $dbh->selectrow_array('SELECT AVG(confidence) FROM crystallized_rules WHERE disabled = 0'),
    };
}

# === PATTERN EXTRACTION ===

sub _extract_patterns {
    my ($self, $conversation) = @_;
    if ($self->{provider}) {
        return $self->_extract_with_llm($conversation);
    }
    return $self->_extract_heuristic($conversation);
}

sub _extract_with_llm {
    my ($self, $conversation) = @_;
    my $provider = $self->{provider};
    my $resp = eval {
        $provider->post_json('/chat/completions', {
            model    => $provider->{model},
            messages => [
                { role => 'system', content =>
                    "Extract reusable rules from this conversation. A rule has:
                     - name: descriptive snake_case name
                     - type: pattern|fact|production
                     - condition: what triggers the rule (regex for pattern, hash for fact)
                     - action: what the rule does (string description or fact assertion)
                     - confidence: 0.0-1.0 how reliable this rule is
                     Return JSON: { rules: [{ name, type, condition, action, confidence }] }
                     Only include rules you are highly confident about." },
                { role => 'user', content => $conversation },
            ],
        }),
    };
    return () unless $resp && $resp->{choices}[0]{message}{content};
    my $data = eval { jdecode($resp->{choices}[0]{message}{content}) };
    return () unless ref $data eq 'HASH' && ref $data->{rules} eq 'ARRAY';
    my @patterns;
    for my $r (@{$data->{rules}}) {
        next unless ref $r eq 'HASH';
        next unless defined $r->{name} && defined $r->{condition} && defined $r->{action};
        push @patterns, {
            name       => $r->{name},
            type       => $r->{type} // 'pattern',
            condition  => $r->{condition},
            action     => $r->{action},
            confidence => $r->{confidence} // 0.7,
        };
    }
    return @patterns;
}

sub _extract_heuristic {
    my ($self, $conversation) = @_;
    my @patterns;
    while ($conversation =~ /\b(\w[\w\s]*?\w)\s+is\s+(.+?)(?:\.|,|\n|$)/gi) {
        my ($subject, $value) = ($1, $2);
        next if length($subject) > 50;
        my $name = lc($subject);
        $name =~ s/\s+/_/g;
        push @patterns, {
            name => "fact_${name}", type => 'fact',
            condition => { type => 'query', match => lc($subject) },
            action    => { type => 'assert', value => "$subject is $value" },
            confidence => 0.6,
        };
    }
    while ($conversation =~ /\bif\s+(.+?)\s+then\s+(.+?)(?:\.|,|\n|$)/gi) {
        my ($condition, $conclusion) = ($1, $2);
        my $name = "rule_" . lc(substr($condition, 0, 30));
        $name =~ s/\s+/_/g; $name =~ s/[^a-z0-9_]//g;
        push @patterns, {
            name => $name, type => 'pattern',
            condition => $condition, action => $conclusion,
            confidence => 0.5,
        };
    }
    return @patterns;
}

# === VALIDATION & STORAGE ===

sub _validate_pattern {
    my ($self, $pattern) = @_;
    my $existing = $self->_dbh->selectrow_array(
        'SELECT COUNT(*) FROM crystallized_rules WHERE name = ? AND disabled = 0',
        undef, $pattern->{name});
    return 0 if $existing > 0;
    return 1;
}

sub _store_rule {
    my ($self, $pattern, %args) = @_;
    my $now = now_ms();
    eval {
        $self->_dbh->prepare(
            'INSERT INTO crystallized_rules (name, rule_type, condition_def, action_def, confidence, source, session_id, created_at) VALUES (?,?,?,?,?,?,?,?)'
        )->execute(
            $pattern->{name}, $pattern->{type},
            ref $pattern->{condition} eq 'HASH' ? jencode($pattern->{condition}) : $pattern->{condition},
            ref $pattern->{action} eq 'HASH' ? jencode($pattern->{action}) : $pattern->{action},
            $pattern->{confidence}, 'crystallized', $args{session_id}, $now,
        );
    };
    return undef if $@;
    return $self->_dbh->last_insert_id(undef, undef, 'crystallized_rules', 'id');
}

sub _register_rule {
    my ($self, $pattern) = @_;
    my $engine = $self->{engine};
    my $condition = $pattern->{condition};
    my $action = $pattern->{action};

    if ($pattern->{type} eq 'pattern' && !ref $condition) {
        my $re = eval { qr/$condition/i };
        return unless $re;
        $condition = $re;
    }
    if ($pattern->{type} eq 'fact' && !ref $action) {
        my $val = $action;
        $action = sub { return { type => 'fact', value => $val } };
    }
    if ($pattern->{type} eq 'production' && ref $condition eq 'HASH') {
        my $act = $action;
        if (ref $act eq 'HASH') {
            my %act_hash = %$act;
            $action = sub { return \%act_hash };
        } elsif (!ref $act) {
            my $val = $act;
            $action = sub { return { type => 'fact', value => $val } };
        }
    }

    my $rule = Clank::Rules::Rule->new(
        name     => $pattern->{name},
        type     => $pattern->{type},
        priority => int($pattern->{confidence} * 100),
        match => ref $condition eq 'Regexp' ? $condition : undef,
        action   => ref $action eq 'CODE' ? $action : sub { return $action },
        weight   => $pattern->{confidence},
    );
    $engine->add($rule);
    $self->{metrics}->inc('crystallized_rules_registered') if $self->{metrics};
}

# === BUS HANDLER ===

sub _on_agent_end {
    my ($self, $ev) = @_;
    return unless $self->{enabled};
    my $session_id = $ev->{payload}{session_id};
    return unless $session_id;
    my $messages = $self->{store}->message_path($session_id);
    return unless @$messages;
    $self->crystallize(session_id => $session_id, conversation => $messages);
}

1;
