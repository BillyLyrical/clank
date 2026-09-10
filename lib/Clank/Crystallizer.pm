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
        project_id  => $args{project_id},
        decay_rate  => $args{decay_rate} // 0.02,
        decay_interval_ms => $args{decay_interval_ms} // (7 * 24 * 60 * 60 * 1000),
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

    # Subscribe to observation bus event for tool-use pattern capture.
    $api->on('observation', sub { $self->_on_observation(@_) });

    # CLI commands for instinct management.
    $api->register_command('instinct',
        description => 'instinct: status|decay|promote|domain <domain>',
        handler => sub { $self->_cmd_instinct(@_) });

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

    # Schema migration: add instinct columns if missing.
    for my $col (
        'scope TEXT DEFAULT \'global\'',
        'project_id TEXT',
        'domain TEXT DEFAULT \'general\'',
        'last_observed INTEGER',
        'decay_rate REAL DEFAULT 0.02',
    ) {
        (my $col_name = $col) =~ s/\s+.*//;
        eval { $self->_dbh->do("ALTER TABLE crystallized_rules ADD COLUMN $col") };
    }
    $self->_dbh->do(qq{
CREATE INDEX IF NOT EXISTS idx_crystallized_scope ON crystallized_rules(scope)});
    $self->_dbh->do(qq{
CREATE INDEX IF NOT EXISTS idx_crystallized_project ON crystallized_rules(project_id)});
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

        $pattern->{scope}      //= $args{scope}      // 'global';
        $pattern->{project_id} //= $args{project_id}  // $self->{project_id} // '';
        $pattern->{domain}     //= $args{domain}      // 'general';

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
        project_scoped => $dbh->selectrow_array("SELECT COUNT(*) FROM crystallized_rules WHERE scope = 'project' AND disabled = 0"),
        global_rules   => $dbh->selectrow_array("SELECT COUNT(*) FROM crystallized_rules WHERE scope = 'global' AND disabled = 0"),
    };
}

# === INSTINCTS: CONFIDENCE DECAY ===

sub apply_decay {
    my ($self, %args) = @_;
    my $now = $args{now} // now_ms();
    my $rate = $args{rate} // $self->{decay_rate};
    my $interval = $args{interval_ms} // $self->{decay_interval_ms};

    my $rules = $self->list_rules(limit => 10000);
    my $decayed = 0;

    for my $rule (@$rules) {
        my $last = $rule->{last_used} // $rule->{created_at} // $now;
        my $elapsed = $now - $last;
        my $periods = int($elapsed / $interval);
        next unless $periods > 0;

        my $rule_rate = $rule->{decay_rate} // $rate;
        my $new_conf = $rule->{confidence} - ($rule_rate * $periods);
        $new_conf = 0 if $new_conf < 0;

        if ($new_conf < $rule->{confidence}) {
            if ($new_conf <= 0) {
                $self->disable_rule($rule->{name});
            }
            else {
                $self->_dbh->do(
                    'UPDATE crystallized_rules SET confidence = ? WHERE name = ?',
                    undef, $new_conf, $rule->{name});
            }
            $decayed++;
        }
    }

    $self->{metrics}->inc('instincts_decayed', $decayed) if $self->{metrics};
    return $decayed;
}

# === INSTINCTS: CONTRADICTION ===

sub detect_contradiction {
    my ($self, $pattern) = @_;
    my $existing = $self->_dbh->selectrow_hashref(
        'SELECT * FROM crystallized_rules WHERE name = ? AND disabled = 0',
        undef, $pattern->{name});
    return undef unless $existing;

    my $existing_text = $existing->{action_def};
    my $new_text = ref $pattern->{action} eq 'HASH' ? jencode($pattern->{action}) : ($pattern->{action} // '');

    if ($existing_text ne $new_text && length($existing_text) > 5 && length($new_text) > 5) {
        my $new_conf = $existing->{confidence} - 0.1;
        $new_conf = 0 if $new_conf < 0;

        if ($new_conf <= 0) {
            $self->disable_rule($existing->{name});
        }
        else {
            $self->_dbh->do(
                'UPDATE crystallized_rules SET confidence = ? WHERE name = ?',
                undef, $new_conf, $existing->{name});
        }
        return { rule => $existing, old_confidence => $existing->{confidence}, new_confidence => $new_conf };
    }

    return undef;
}

# === INSTINCTS: PROMOTION (project -> global) ===

sub promote_rules {
    my ($self, %args) = @_;
    my $min_confidence = $args{min_confidence} // 0.8;

    my $candidates = $self->_dbh->selectall_arrayref(
        sprintf(q{SELECT name, COUNT(DISTINCT project_id) as project_count, AVG(confidence) as avg_conf
          FROM crystallized_rules
          WHERE scope = 'project' AND disabled = 0
          GROUP BY name
          HAVING project_count >= 2 AND avg_conf >= %s}, $min_confidence),
        { Slice => {} });

    my $promoted = 0;
    for my $c (@$candidates) {
        $self->_dbh->do(
            "UPDATE crystallized_rules SET scope = 'global' WHERE name = ? AND scope = 'project'",
            undef, $c->{name});
        $promoted++;
    }

    $self->{metrics}->inc('instincts_promoted', $promoted) if $self->{metrics};
    return $promoted;
}

# === INSTINCTS: OBSERVATION ===

sub observe {
    my ($self, %args) = @_;
    my $tool_name = $args{tool} // '';
    my $input     = $args{input} // {};
    my $output    = $args{output} // '';
    my $success   = $args{success} // 1;
    my $domain    = $args{domain} // 'general';

    my $now = now_ms();
    my $project_id = $args{project_id} // $self->{project_id} // '';

    # Update last_observed for matching rules.
    my $rules = $self->list_rules(limit => 10000);
    my $observed = 0;
    for my $rule (@$rules) {
        my $text = join(' ', $rule->{name} // '', $rule->{condition_def} // '', $rule->{action_def} // '');
        if ($text =~ /\Q$tool_name\E/i) {
            $self->_dbh->do(
                'UPDATE crystallized_rules SET last_observed = ?, use_count = use_count + 1 WHERE name = ?',
                undef, $now, $rule->{name});
            $observed++;
        }
    }

    $self->{metrics}->inc('observations', 1) if $self->{metrics};
    return $observed;
}

# === INSTINCTS: PROJECT DETECTION ===

sub detect_project_id {
    my ($class, %args) = @_;
    my $path = $args{path} // '.';

    my $remote = eval {
        chomp(my $url = `git -C $path remote get-url origin 2>/dev/null`);
        $url;
    };

    if ($remote && $remote =~ /\S/) {
        return _hash_string($remote);
    }

    my $toplevel = eval {
        chomp(my $dir = `git -C $path rev-parse --show-toplevel 2>/dev/null`);
        $dir;
    };

    if ($toplevel && $toplevel =~ /\S/) {
        return _hash_string($toplevel);
    }

    return undef;
}

sub _hash_string {
    my ($str) = @_;
    my $hash = 0;
    $hash = ($hash * 33 + ord($_)) & 0xFFFFFFFF for split //, $str;
    return sprintf('%08x', $hash);
}

# === INSTINCTS: LIST BY SCOPE ===

sub list_instincts {
    my ($self, %args) = @_;
    my $scope   = $args{scope};   # undef = all
    my $domain  = $args{domain};  # undef = all
    my $limit   = $args{limit} // 100;

    my @where = ('disabled = 0');
    my @bind;
    if (defined $scope) {
        push @where, 'scope = ?';
        push @bind, $scope;
    }
    if (defined $domain) {
        push @where, 'domain = ?';
        push @bind, $domain;
    }

    my $sql = 'SELECT * FROM crystallized_rules WHERE ' . join(' AND ', @where);
    $sql .= ' ORDER BY confidence DESC LIMIT ?';
    push @bind, $limit;

    return $self->_dbh->selectall_arrayref($sql, { Slice => {} }, @bind);
}

# === CLI COMMANDS ===

sub _cmd_instinct {
    my ($self, $ctx, $args) = @_;
    my ($subcmd, @rest) = split /\s+/, ($args // '');
    $subcmd //= 'status';

    if ($subcmd eq 'status') {
        my $s = $self->stats;
        my $out = "Instinct status:\n";
        $out .= "  total rules: $s->{total_rules}\n";
        $out .= "  active: $s->{active}\n";
        $out .= "  project-scoped: $s->{project_scoped}\n";
        $out .= "  global: $s->{global_rules}\n";
        $out .= "  avg confidence: " . sprintf('%.1f%%', ($s->{avg_confidence} // 0) * 100) . "\n";
        $out .= "  total uses: $s->{total_uses}\n";

        my $project = $self->{project_id} // 'none';
        $out .= "  project_id: $project\n";

        my $instincts = $self->list_instincts(limit => 10);
        if (@$instincts) {
            $out .= "\nTop instincts:\n";
            for my $i (@$instincts) {
                $out .= sprintf("  %.0f%% %s [%s] (used %d)\n",
                    ($i->{confidence} // 0) * 100,
                    $i->{name}, $i->{scope} // 'global',
                    $i->{use_count} // 0);
            }
        }
        return $out;
    }
    elsif ($subcmd eq 'decay') {
        my $decayed = $self->apply_decay;
        return "Decay applied: $decayed rules affected.\n";
    }
    elsif ($subcmd eq 'promote') {
        my $promoted = $self->promote_rules;
        return "Promotion: $promoted rules promoted to global.\n";
    }
    elsif ($subcmd eq 'domain') {
        my $domain = $rest[0] // '';
        return "Usage: /instinct domain <domain>\n" unless $domain;
        my $instincts = $self->list_instincts(domain => $domain);
        my $out = "Instincts in domain '$domain':\n";
        for my $i (@$instincts) {
            $out .= sprintf("  %.0f%% %s [%s]\n",
                ($i->{confidence} // 0) * 100, $i->{name}, $i->{scope} // 'global');
        }
        $out .= "  (none)\n" unless @$instincts;
        return $out;
    }

    return "Usage: /instinct status|decay|promote|domain <domain>\n";
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
    my $scope = $pattern->{scope} // 'global';
    my $project_id = $pattern->{project_id} // $self->{project_id} // '';
    my $domain = $pattern->{domain} // 'general';

    eval {
        $self->_dbh->prepare(
            'INSERT INTO crystallized_rules (name, rule_type, condition_def, action_def, confidence, source, session_id, created_at, last_observed, scope, project_id, domain) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)'
        )->execute(
            $pattern->{name}, $pattern->{type},
            ref $pattern->{condition} eq 'HASH' ? jencode($pattern->{condition}) : $pattern->{condition},
            ref $pattern->{action} eq 'HASH' ? jencode($pattern->{action}) : $pattern->{action},
            $pattern->{confidence}, 'crystallized', $args{session_id}, $now, $now,
            $scope, $project_id, $domain,
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

sub _on_observation {
    my ($self, $ev) = @_;
    return unless $self->{enabled};
    my $p = $ev->{payload} // {};
    $self->observe(
        tool      => $p->{tool} // '',
        input     => $p->{input} // {},
        output    => $p->{output} // '',
        success   => $p->{success} // 1,
        domain    => $p->{domain} // 'general',
        project_id => $p->{project_id} // $self->{project_id},
    );
}

1;
