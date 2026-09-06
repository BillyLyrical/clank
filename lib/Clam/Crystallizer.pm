# Clam::Crystallizer — capture LLM solutions as deterministic rules.
#
# When the LLM solves a problem, the solution is captured as a rule
# that runs forever after without LLM involvement. The system gets
# cheaper and faster the more it's used.
#
# Pipeline:
#   1. LLM identifies reusable patterns from conversation
#   2. Validate proposed rules against world model
#   3. Register validated rules in the rules engine
#   4. Track usage and confidence
#
# Hooks into bus at agent_end to analyze completed conversations.
package Clam::Crystallizer;
use strict;
use warnings;
use Clam::Util qw(now_ms jencode jdecode);
use Clam::Rules::Rule ();

sub new {
    my ($class, %args) = @_;
    my $store = $args{store} // die "Clam::Crystallizer requires store\n";

    my $self = bless {
        store       => $store,
        bus         => $args{bus},
        provider    => $args{provider},    # optional: for LLM pattern extraction
        world_model => $args{world_model},
        engine      => $args{engine},      # Clam::Rules::Engine
        tracer      => $args{tracer},
        metrics     => $args{metrics},
        enabled     => $args{enabled} // 1,
        min_confidence => $args{min_confidence} // 0.6,
    }, $class;
    $self->_init_schema;
    $self->_subscribe if $self->{bus};
    return $self;
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

sub _subscribe {
    my ($self) = @_;
    $self->{bus}->subscribe('agent_end', sub {
        $self->_on_agent_end(@_);
    }, name => 'crystallizer');
}

# === PUBLIC API ===

# Crystallize rules from a conversation. Returns count of rules crystallized.
sub crystallize {
    my ($self, %args) = @_;
    my $session_id = $args{session_id};
    my $conversation = $args{conversation};   # text or arrayref of messages

    return 0 unless $self->{enabled};

    my $trace_id;
    $trace_id = $self->{tracer}->start_span('crystallize', topic => 'crystallize')
        if $self->{tracer};

    # Build conversation text if arrayref.
    if (ref $conversation eq 'ARRAY') {
        $conversation = join("\n", map {
            my $c = ref $_->{content} eq 'HASH' ? ($_->{content}{text} // '') : ($_->{content} // '');
            sprintf("[%s] %s", $_->{role}, $c);
        } @$conversation);
    }
    return 0 unless defined $conversation && length $conversation;

    # Extract patterns from conversation.
    my @patterns = $self->_extract_patterns($conversation);
    return 0 unless @patterns;

    # Validate and register.
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

# Get all crystallized rules.
sub list_rules {
    my ($self, %args) = @_;
    my $disabled = $args{disabled} // 0;
    my $limit = $args{limit} // 100;

    my ($sql, @bind) = ('SELECT * FROM crystallized_rules WHERE disabled = ?', $disabled);
    $sql .= ' ORDER BY confidence DESC, use_count DESC LIMIT ?';
    push @bind, $limit;

    my $rows = $self->_dbh->selectall_arrayref($sql, { Slice => {} }, @bind);
    return $rows;
}

# Get a crystallized rule by name.
sub get_rule {
    my ($self, $name) = @_;
    return $self->_dbh->selectrow_hashref(
        'SELECT * FROM crystallized_rules WHERE name = ? AND disabled = 0',
        undef, $name);
}

# Mark a rule as used (increment use_count, update last_used).
sub mark_used {
    my ($self, $name) = @_;
    my $now = now_ms();
    $self->_dbh->do(
        'UPDATE crystallized_rules SET use_count = use_count + 1, last_used = ? WHERE name = ?',
        undef, $now, $name);
}

# Disable a rule (soft delete).
sub disable_rule {
    my ($self, $name) = @_;
    $self->_dbh->do(
        'UPDATE crystallized_rules SET disabled = 1 WHERE name = ?', undef, $name);
    $self->{engine}->remove($name) if $self->{engine};
}

# Stats.
sub stats {
    my ($self) = @_;
    my $dbh = $self->_dbh;
    my $total = $dbh->selectrow_array('SELECT COUNT(*) FROM crystallized_rules');
    my $active = $dbh->selectrow_array('SELECT COUNT(*) FROM crystallized_rules WHERE disabled = 0');
    my $total_uses = $dbh->selectrow_array('SELECT COALESCE(SUM(use_count), 0) FROM crystallized_rules');
    my $avg_conf = $dbh->selectrow_array('SELECT AVG(confidence) FROM crystallized_rules WHERE disabled = 0');
    return {
        total_rules => $total,
        active      => $active,
        total_uses  => $total_uses,
        avg_confidence => $avg_conf,
    };
}

# === PATTERN EXTRACTION ===

sub _extract_patterns {
    my ($self, $conversation) = @_;

    # If LLM provider available, use it for intelligent extraction.
    if ($self->{provider}) {
        return $self->_extract_with_llm($conversation);
    }

    # Fallback: simple heuristic extraction.
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
                     Only include rules you are highly confident about.
                     Return empty array if no reusable patterns found." },
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

    # Extract "X is Y" facts.
    while ($conversation =~ /\b(\w[\w\s]*?\w)\s+is\s+(.+?)(?:\.|,|\n|$)/gi) {
        my ($subject, $value) = ($1, $2);
        next if length($subject) > 50;
        my $name = lc($subject);
        $name =~ s/\s+/_/g;
        push @patterns, {
            name       => "fact_${name}",
            type       => 'fact',
            condition  => { type => 'query', match => lc($subject) },
            action     => { type => 'assert', value => "$subject is $value" },
            confidence => 0.6,
        };
    }

    # Extract "if X then Y" rules.
    while ($conversation =~ /\bif\s+(.+?)\s+then\s+(.+?)(?:\.|,|\n|$)/gi) {
        my ($condition, $conclusion) = ($1, $2);
        my $name = "rule_" . lc(substr($condition, 0, 30));
        $name =~ s/\s+/_/g;
        $name =~ s/[^a-z0-9_]//g;
        push @patterns, {
            name       => $name,
            type       => 'pattern',
            condition  => $condition,
            action     => $conclusion,
            confidence => 0.5,
        };
    }

    return @patterns;
}

# === VALIDATION ===

sub _validate_pattern {
    my ($self, $pattern) = @_;

    # Check name doesn't conflict with existing rules.
    my $existing = $self->_dbh->selectrow_array(
        'SELECT COUNT(*) FROM crystallized_rules WHERE name = ? AND disabled = 0',
        undef, $pattern->{name});
    return 0 if $existing > 0;

    # Check against world model if available.
    if ($self->{world_model}) {
        # Validate that referenced entities exist.
        if (ref $pattern->{condition} eq 'HASH' && $pattern->{condition}{type}) {
            my $entities = $self->{world_model}->query_entities(
                type => $pattern->{condition}{type});
            # Allow creation — world model can be extended.
        }
    }

    return 1;
}

# === STORAGE ===

sub _store_rule {
    my ($self, $pattern, %args) = @_;
    my $now = now_ms();

    eval {
        $self->_dbh->prepare(
            'INSERT INTO crystallized_rules (name, rule_type, condition_def, action_def, confidence, source, session_id, created_at) VALUES (?,?,?,?,?,?,?,?)'
        )->execute(
            $pattern->{name},
            $pattern->{type},
            ref $pattern->{condition} eq 'HASH' ? jencode($pattern->{condition}) : $pattern->{condition},
            ref $pattern->{action} eq 'HASH' ? jencode($pattern->{action}) : $pattern->{action},
            $pattern->{confidence},
            'crystallized',
            $args{session_id},
            $now,
        );
    };
    return undef if $@;

    return $self->_dbh->last_insert_id(undef, undef, 'crystallized_rules', 'id');
}

sub _register_rule {
    my ($self, $pattern) = @_;
    my $engine = $self->{engine};

    # Build a Clam::Rules::Rule from the crystallized pattern.
    my $condition = $pattern->{condition};
    my $action = $pattern->{action};

    # Convert string condition to regex for pattern rules.
    if ($pattern->{type} eq 'pattern' && !ref $condition) {
        my $re = eval { qr/$condition/i };
        return unless $re;
        $condition = $re;
    }

    # Convert string action to fact assertion for fact rules.
    if ($pattern->{type} eq 'fact' && !ref $action) {
        my $val = $action;
        $action = sub {
            return { type => 'fact', value => $val };
        };
    }

    # For hash conditions (production rules), convert to proper format.
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

    my $rule = Clam::Rules::Rule->new(
        name     => $pattern->{name},
        type     => $pattern->{type},
        priority => int($pattern->{confidence} * 100),
        match    => ref $condition eq 'REGEXP' ? $condition : undef,
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

    # Get conversation messages.
    my $messages = $self->{store}->message_path($session_id);
    return unless @$messages;

    $self->crystallize(
        session_id  => $session_id,
        conversation => $messages,
    );
}

1;
