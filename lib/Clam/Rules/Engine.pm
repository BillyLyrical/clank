# Clam::Rules::Engine — pluggable inference over rules. Strategies: first,
# random, probabilistic, all; plus forward chaining (production rules).
#
# Features:
#   1. Forward chaining — production rules fire until fixpoint
#   2. Backward chaining — goal-directed reasoning ("Why is X true?")
#   3. Negation as failure — not_exists(type => X) conditions
#   4. Conflict resolution — priority enforcement during chaining
#   5. Rule composition — rules can call other rules' outputs
#   6. Incremental re-evaluation — only re-evaluate dependent rules
#
# Facts live in the shared SQLite store (Clam::Store) — the blackboard every
# agent on this DB reads and writes. The engine keeps an in-memory working set
# over it so chain() doesn't re-query per condition check; assert/retract keep
# both in sync, and a fresh engine on the same DB sees everything already there.
package Clam::Rules::Engine;
use strict;
use warnings;
use Clam::Rules::Rule ();   # load() constructs these

sub new {
    my ($class, %args) = @_;
    die "Clam::Rules::Engine requires a store (Clam::Store)" unless $args{store};
    my $self = bless {
        store           => $args{store},
        rules           => [],                 # sorted by priority
        facts           => {},                 # type => [ fact, ... ] working set
        strategy        => $args{strategy} // 'first',   # first|random|probabilistic|all
        max_chain_depth => $args{max_chain_depth} // 50,
        chain_log       => [],                 # trace of last chain() run
        rule_deps       => {},                 # rule_name => [fact_types it depends on]
        goal_cache      => {},                 # goal => { proven => bool, proof => [...] }
    }, $class;
    $self->_load_facts;
    return $self;
}

# Load the shared fact store into the working set.
sub _load_facts {
    my ($self) = @_;
    for my $f (@{ $self->{store}->query_facts() }) {
        push $self->{facts}{$f->{type}}->@*, $f;
    }
}

# Register a rule. Maintains priority order (higher first).
sub add {
    my ($self, $rule) = @_;
    push $self->{rules}->@*, $rule;
    $self->{rules} = [ sort { $b->priority <=> $a->priority } $self->{rules}->@* ];
}

# Remove a rule by name.
sub remove {
    my ($self, $name) = @_;
    $self->{rules} = [ grep { $_->name ne $name } $self->{rules}->@* ];
}

# Load rules from an arrayref of rule configs (hashrefs for Clam::Rules::Rule).
sub load {
    my ($self, $rule_configs) = @_;
    for my $cfg (@$rule_configs) {
        $self->add(Clam::Rules::Rule->new(%$cfg));
    }
}

# Get a registered rule by name.
sub get_rule {
    my ($self, $name) = @_;
    for my $r ($self->{rules}->@*) {
        return $r if $r->name eq $name;
    }
    return undef;
}

# === FACT STORE (SQLite-backed shared blackboard) ===

# Assert a fact. Returns the stored row ({id,type,attributes,asserted_by,created_at}).
sub assert_fact {
    my ($self, $type, $attributes, $meta) = @_;
    $attributes //= {};
    $meta       //= {};
    my $id   = $self->{store}->assert_fact($type, $attributes, $meta);
    my $fact = {
        id          => $id,
        type        => $type,
        attributes  => $attributes,
        asserted_by => $meta->{asserted_by} // 'external',
    };
    push $self->{facts}{$type}->@*, $fact;
    return $fact;
}

# Retract (remove) a fact by id.
sub retract_fact {
    my ($self, $fact_id) = @_;
    $self->{store}->retract_fact($fact_id);
    for my $type (keys $self->{facts}->%*) {
        $self->{facts}{$type} = [ grep { $_->{id} ne $fact_id } @{ $self->{facts}{$type} } ];
    }
    return 1;
}

# Query facts by type and optional filter sub. Reads the working set.
sub query_facts {
    my ($self, $type, $filter) = @_;
    my $facts = $self->{facts}{$type} // [];
    return [ @$facts ] unless $filter;
    return [ grep { $filter->($_) } @$facts ];
}

# Get all facts as a flat list.
sub all_facts {
    my ($self) = @_;
    my @all;
    for my $type (sort keys $self->{facts}->%*) {
        push @all, $self->{facts}{$type}->@*;
    }
    return \@all;
}

# Count facts by type (or all types).
sub fact_count {
    my ($self, $type) = @_;
    if ($type) {
        return scalar @{ $self->{facts}{$type} // [] };
    }
    my $total = 0;
    $total += scalar @{ $self->{facts}{$_} } for keys $self->{facts}->%*;
    return $total;
}

# Clear all facts (store + working set).
sub clear_facts {
    my ($self) = @_;
    $self->{store}->clear_facts;
    $self->{facts} = {};
}

# === FORWARD CHAINING ===

# Fire forward chaining: assert initial facts → match production rules → fire →
# assert new facts → repeat until fixpoint or max depth.
# Returns { iterations, facts_asserted, rules_fired, max_reached, log }.
sub chain {
    my ($self, $initial_facts) = @_;
    $self->{chain_log} = [];
    my $iterations     = 0;
    my $facts_asserted = 0;
    my $rules_fired    = 0;

    # Assert initial facts.
    if (ref $initial_facts eq 'ARRAY') {
        for my $f (@$initial_facts) {
            if (ref $f eq 'HASH') {
                $self->assert_fact($f->{type}, $f->{attributes}, { asserted_by => 'initial' });
                $facts_asserted++;
            } elsif (!ref $f) {
                $self->assert_fact("$f", {}, { asserted_by => 'initial' });
                $facts_asserted++;
            }
        }
    }

    # Chain until no new rules fire or max depth.
    while ($iterations < $self->{max_chain_depth}) {
        my @fired_this_iter;

        for my $rule ($self->{rules}->@*) {
            next unless $rule->enabled;
            next if $rule->type ne 'production';

            # Test if rule conditions match current facts.
            my $matched = $self->_match_production($rule);
            next unless $matched;

            # Execute rule action — produces new fact(s).
            my $result = $rule->execute({ facts => $self->{facts}, match => $matched->{facts}[0] });
            next unless defined $result;

            # Handle result: single fact or array of facts.
            my @new_facts = ref $result eq 'ARRAY' ? @$result : ($result);
            my $asserted_any = 0;

            for my $nf (@new_facts) {
                next unless ref $nf eq 'HASH' && $nf->{type};

                # Check for duplicate facts (same type + attributes).
                next if $self->_fact_exists($nf->{type}, $nf->{attributes} // {});

                $self->assert_fact(
                    $nf->{type},
                    $nf->{attributes} // {},
                    { asserted_by => $rule->name },
                );
                $facts_asserted++;
                $asserted_any = 1;
                push @fired_this_iter, {
                    rule    => $rule->name,
                    fact    => $nf->{type},
                    details => $nf->{attributes} // {},
                };
            }

            # Count a firing only when it actually produced new knowledge —
            # re-matching on the next iteration with all outputs suppressed as
            # duplicates is not a fire (old code counted those too).
            $rules_fired++ if $asserted_any;
        }

        # Log this iteration.
        push $self->{chain_log}->@*, {
            iteration => $iterations + 1,
            fired     => scalar @fired_this_iter,
            rules     => \@fired_this_iter,
        };

        # No new facts produced → chain complete.
        last unless @fired_this_iter;
        $iterations++;
    }

    return {
        iterations     => $iterations,
        facts_asserted => $facts_asserted,
        rules_fired    => $rules_fired,
        max_reached    => $iterations >= $self->{max_chain_depth},
        log            => $self->{chain_log},
    };
}

# Test if a production rule's conditions match current facts.
sub _match_production {
    my ($self, $rule) = @_;
    my $conditions = $rule->{conditions} // [];
    return undef unless @$conditions;

    my %bindings;
    my @matched_facts;
    for my $cond (@$conditions) {
        my $matched_fact = $self->_match_condition_with_negation($cond);
        return undef unless $matched_fact;
        push @matched_facts, $matched_fact;
        if ($cond->{bind}) {
            $bindings{$cond->{bind}} = $matched_fact;
        }
    }

    return { bindings => \%bindings, facts => \@matched_facts };
}

# Test a single condition against the fact store.
sub _match_condition {
    my ($self, $cond) = @_;
    my $type  = $cond->{type} // return undef;
    my $facts = $self->{facts}{$type} // [];

    for my $fact (@$facts) {
        my $attrs = $fact->{attributes} // {};
        my $match = 1;

        for my $key (keys %$cond) {
            next if $key eq 'type';
            next if $key eq 'bind';
            next if $key eq 'op';

            my $op       = $cond->{op} // 'eq';
            my $expected = $cond->{$key};
            my $actual   = $attrs->{$key};

            if ($op eq 'eq') {
                $match = 0 unless defined $actual && "$actual" eq "$expected";
            } elsif ($op eq 'ne') {
                $match = 0 if defined $actual && "$actual" eq "$expected";
            } elsif ($op eq 'gt') {
                $match = 0 unless defined $actual && $actual > $expected;
            } elsif ($op eq 'ge') {
                $match = 0 unless defined $actual && $actual >= $expected;
            } elsif ($op eq 'lt') {
                $match = 0 unless defined $actual && $actual < $expected;
            } elsif ($op eq 'le') {
                $match = 0 unless defined $actual && $actual <= $expected;
            } elsif ($op eq 'exists') {
                $match = 0 unless exists $attrs->{$key};
            } elsif ($op eq 'regex') {
                $match = 0 unless defined $actual && $actual =~ /$expected/;
            } else {
                # Default: equality.
                $match = 0 unless defined $actual && "$actual" eq "$expected";
            }

            last unless $match;
        }

        return $fact if $match;
    }

    return undef;
}

# Check if a fact with given type and attributes already exists.
sub _fact_exists {
    my ($self, $type, $attrs) = @_;
    my $facts = $self->{facts}{$type} // [];
    for my $f (@$facts) {
        my $fa   = $f->{attributes} // {};
        my $same = 1;
        for my $k (keys %$attrs) {
            unless (defined $fa->{$k} && "$fa->{$k}" eq "$attrs->{$k}") {
                $same = 0;
                last;
            }
        }
        return 1 if $same;
    }
    return 0;
}

# === EXECUTION STRATEGIES ===

# Execute rules against context. Returns result based on strategy:
#   first         -> first matching rule's result (priority order)
#   random        -> one random match's result
#   probabilistic -> weighted-random; hash results gain _confidence
#   all           -> arrayref of every match's result (+_confidence,_rule)
sub execute {
    my ($self, $context) = @_;

    my @matches;
    for my $rule ($self->{rules}->@*) {
        my $score = $rule->test($context);
        next unless $score > 0;
        push @matches, { rule => $rule, score => $score };
    }

    return undef unless @matches;

    if ($self->{strategy} eq 'first') {
        return $matches[0]{rule}->execute($context);
    }
    elsif ($self->{strategy} eq 'random') {
        my $pick = $matches[rand @matches];
        return $pick->{rule}->execute($context);
    }
    elsif ($self->{strategy} eq 'probabilistic') {
        my $total      = 0;
        $total += $_->{score} for @matches;
        my $rand       = rand($total);
        my $cumulative = 0;
        for my $m (@matches) {
            $cumulative += $m->{score};
            if ($rand <= $cumulative) {
                my $result = $m->{rule}->execute($context);
                $result->{_confidence} = $m->{score} if ref $result eq 'HASH';
                return $result;
            }
        }
        my $last   = $matches[-1];
        my $result = $last->{rule}->execute($context);
        $result->{_confidence} = $last->{score} if ref $result eq 'HASH';
        return $result;
    }
    elsif ($self->{strategy} eq 'all') {
        my @results;
        for my $m (@matches) {
            my $result = $m->{rule}->execute($context);
            if (ref $result eq 'HASH') {
                $result->{_confidence} = $m->{score};
                $result->{_rule}       = $m->{rule}->name;
            }
            push @results, $result if defined $result;
        }
        return \@results;
    }

    return undef;
}

# First matching rule (priority order), or undef.
sub find {
    my ($self, $context) = @_;
    for my $rule ($self->{rules}->@*) {
        return $rule if $rule->test($context);
    }
    return undef;
}

# All matching rules (priority order).
sub find_all {
    my ($self, $context) = @_;
    return [ grep { $_->test($context) } $self->{rules}->@* ];
}

# List registered rules as plain data.
sub list {
    my ($self) = @_;
    return [ map { { name => $_->name, type => $_->type, priority => $_->priority, enabled => $_->enabled } } $self->{rules}->@* ];
}

sub set_strategy { $_[0]->{strategy} = $_[1] }
sub strategy     { return $_[0]->{strategy} }
sub chain_log    { return $_[0]->{chain_log} }
sub store        { return $_[0]->{store} }
sub clear_cache  { $_[0]->{goal_cache} = {} }

# === BACKWARD CHAINING ===

# Prove a goal is true by working backward through rules.
# Returns { proven => bool, proof => [...], steps => [...] }
sub prove {
    my ($self, $goal_type, $goal_attrs) = @_;
    $goal_attrs //= {};
    
    # Check cache first.
    my $cache_key = "$goal_type:" . join(',', sort keys %$goal_attrs);
    return $self->{goal_cache}{$cache_key} if exists $self->{goal_cache}{$cache_key};
    
    my @proof_steps;
    my $result = $self->_prove_goal($goal_type, $goal_attrs, \@proof_steps, 0);
    
    my $proof = {
        proven => $result,
        proof  => \@proof_steps,
        steps  => scalar @proof_steps,
    };
    
    $self->{goal_cache}{$cache_key} = $proof;
    return $proof;
}

sub _prove_goal {
    my ($self, $goal_type, $goal_attrs, $steps, $depth) = @_;
    
    # Prevent infinite recursion.
    return 0 if $depth > $self->{max_chain_depth};
    
    # Check if fact already exists.
    if ($self->_fact_exists($goal_type, $goal_attrs)) {
        push @$steps, {
            step    => scalar @$steps + 1,
            action  => 'fact_exists',
            type    => $goal_type,
            attrs   => $goal_attrs,
            success => 1,
        };
        return 1;
    }
    
    # Try to prove via production rules.
    for my $rule ($self->{rules}->@*) {
        next unless $rule->enabled;
        next unless $rule->type eq 'production';
        
        # Try to prove the rule's conditions first.
        my $conditions = $rule->{conditions} // [];
        my $all_conditions_proven = 1;
        my @condition_proofs;
        
        for my $cond (@$conditions) {
            my $cond_type = $cond->{type} // next;
            
            # Handle negation as failure.
            if ($cond->{not_exists}) {
                my $exists = $self->_fact_exists($cond_type, { %$cond, not_exists => 1, type => 1, bind => 1, op => 1 });
                push @condition_proofs, {
                    condition => $cond,
                    proven    => !$exists,
                    negation  => 1,
                };
                unless ($exists) {
                    $all_conditions_proven = 0;
                    last;
                }
                next;
            }
            
            # Regular condition - prove recursively.
            my %cond_attrs;
            for my $k (keys %$cond) {
                next if $k eq 'type';
                next if $k eq 'bind';
                next if $k eq 'op';
                $cond_attrs{$k} = $cond->{$k};
            }
            
            my $cond_proven = $self->_prove_goal($cond_type, \%cond_attrs, $steps, $depth + 1);
            push @condition_proofs, {
                condition => $cond,
                proven    => $cond_proven,
            };
            
            unless ($cond_proven) {
                $all_conditions_proven = 0;
                last;
            }
        }
        
        next unless $all_conditions_proven;
        
        # All conditions proven - check if this rule can produce the goal type.
        my $action = $rule->{action};
        next unless ref $action eq 'CODE';
        
        # Build a match from the proven conditions.
        my $match_data = {};
        for my $proof (@condition_proofs) {
            my $cond = $proof->{condition};
            if ($cond->{bind}) {
                $match_data->{$cond->{bind}} = $proof->{matched_fact} // {};
            }
        }
        
        my $test_context = { facts => $self->{facts}, match => $match_data };
        my $result = eval { $action->($test_context) };
        next unless defined $result;
        
        # Check if result matches goal.
        my @results = ref $result eq 'ARRAY' ? @$result : ($result);
        my $matched = 0;
        
        for my $r (@results) {
            next unless ref $r eq 'HASH' && $r->{type};
            if ($r->{type} eq $goal_type) {
                my $attrs_match = 1;
                for my $k (keys %$goal_attrs) {
                    unless (defined $r->{attributes}{$k} && "$r->{attributes}{$k}" eq "$goal_attrs->{$k}") {
                        $attrs_match = 0;
                        last;
                    }
                }
                if ($attrs_match) {
                    $matched = 1;
                    last;
                }
            }
        }
        
        if ($matched) {
            push @$steps, {
                step        => scalar @$steps + 1,
                action      => 'rule_applied',
                rule        => $rule->name,
                goal_type   => $goal_type,
                goal_attrs  => $goal_attrs,
                conditions  => \@condition_proofs,
                success     => 1,
            };
            return 1;
        }
    }
    
    push @$steps, {
        step    => scalar @$steps + 1,
        action  => 'goal_unprovable',
        type    => $goal_type,
        attrs   => $goal_attrs,
        success => 0,
    };
    return 0;
}

# === NEGATION AS FAILURE ===

# Check if a fact does NOT exist (negation as failure).
sub not_exists {
    my ($self, $type, $attrs) = @_;
    $attrs //= {};
    return !$self->_fact_exists($type, $attrs);
}

# Enhanced _match_condition with negation support.
sub _match_condition_with_negation {
    my ($self, $cond) = @_;
    
    # Handle not_exists conditions.
    if ($cond->{not_exists}) {
        my $type = $cond->{type} // return undef;
        my @check_attrs;
        for my $k (keys %$cond) {
            next if $k eq 'type';
            next if $k eq 'bind';
            next if $k eq 'op';
            next if $k eq 'not_exists';
            push @check_attrs, ($k, $cond->{$k});
        }
        my $exists = $self->_fact_exists($type, {@check_attrs});
        return { _negation => 1, _result => !$exists };
    }
    
    return $self->_match_condition($cond);
}

# === CONFLICT RESOLUTION ===

# Resolve conflicts when multiple rules fire simultaneously.
# Returns the winning rule based on strategy.
sub resolve_conflicts {
    my ($self, @fired_rules) = @_;
    
    return () unless @fired_rules;
    return ($fired_rules[0]) if @fired_rules == 1;
    
    if ($self->{strategy} eq 'first') {
        # Highest priority wins.
        return ((sort { $b->priority <=> $a->priority } @fired_rules)[0]);
    }
    elsif ($self->{strategy} eq 'random') {
        return ($fired_rules[rand @fired_rules]);
    }
    elsif ($self->{strategy} eq 'probabilistic') {
        my $total = 0;
        $total += $_->weight for @fired_rules;
        my $rand = rand($total);
        my $cumulative = 0;
        for my $rule (@fired_rules) {
            $cumulative += $rule->weight;
            return ($rule) if $rand <= $cumulative;
        }
        return ($fired_rules[-1]);
    }
    elsif ($self->{strategy} eq 'all') {
        return @fired_rules;
    }
    
    return ($fired_rules[0]);
}

# Enhanced forward chaining with conflict resolution.
sub chain_with_resolution {
    my ($self, $initial_facts) = @_;
    $self->{chain_log} = [];
    my $iterations     = 0;
    my $facts_asserted = 0;
    my $rules_fired    = 0;
    
    # Assert initial facts.
    if (ref $initial_facts eq 'ARRAY') {
        for my $f (@$initial_facts) {
            if (ref $f eq 'HASH') {
                $self->assert_fact($f->{type}, $f->{attributes}, { asserted_by => 'initial' });
                $facts_asserted++;
            } elsif (!ref $f) {
                $self->assert_fact("$f", {}, { asserted_by => 'initial' });
                $facts_asserted++;
            }
        }
    }
    
    # Chain until no new rules fire or max depth.
    while ($iterations < $self->{max_chain_depth}) {
        my @fired_this_iter;
        my @all_fired_rules;
        
        # Collect all matching rules first.
        for my $rule ($self->{rules}->@*) {
            next unless $rule->enabled;
            next if $rule->type ne 'production';
            
            my $matched = $self->_match_production($rule);
            next unless $matched;
            
            push @all_fired_rules, { rule => $rule, match => $matched };
        }
        
        # Resolve conflicts and execute winners.
        my @winner_rules = $self->resolve_conflicts(map { $_->{rule} } @all_fired_rules);
        my %winner_names = map { $_->name => 1 } @winner_rules;
        
        for my $fired (@all_fired_rules) {
            my $rule = $fired->{rule};
            next unless $winner_names{$rule->name};
            
            my $result = $rule->execute({ facts => $self->{facts}, match => $fired->{match}{facts}[0] });
            next unless defined $result;
            
            my @new_facts = ref $result eq 'ARRAY' ? @$result : ($result);
            my $asserted_any = 0;
            
            for my $nf (@new_facts) {
                next unless ref $nf eq 'HASH' && $nf->{type};
                next if $self->_fact_exists($nf->{type}, $nf->{attributes} // {});
                
                $self->assert_fact(
                    $nf->{type},
                    $nf->{attributes} // {},
                    { asserted_by => $rule->name },
                );
                $facts_asserted++;
                $asserted_any = 1;
                push @fired_this_iter, {
                    rule    => $rule->name,
                    fact    => $nf->{type},
                    details => $nf->{attributes} // {},
                };
            }
            
            $rules_fired++ if $asserted_any;
        }
        
        push $self->{chain_log}->@*, {
            iteration => $iterations + 1,
            fired     => scalar @fired_this_iter,
            rules     => \@fired_this_iter,
        };
        
        last unless @fired_this_iter;
        $iterations++;
    }
    
    return {
        iterations     => $iterations,
        facts_asserted => $facts_asserted,
        rules_fired    => $rules_fired,
        max_reached    => $iterations >= $self->{max_chain_depth},
        log            => $self->{chain_log},
    };
}

# === RULE COMPOSITION ===

# Execute a pipeline of rules, passing output of one as input to the next.
sub chain_rules {
    my ($self, @rule_names) = @_;
    
    return undef unless @rule_names;
    
    my $context = { facts => $self->{facts} };
    my @pipeline_trace;
    
    for my $name (@rule_names) {
        my $rule = $self->get_rule($name);
        unless ($rule) {
            push @pipeline_trace, {
                rule   => $name,
                error  => 'rule not found',
                result => undef,
            };
            last;
        }
        
        my $result = $rule->execute($context);
        push @pipeline_trace, {
            rule   => $name,
            input  => $context,
            result => $result,
        };
        
        # Pass result as context for next rule.
        if (ref $result eq 'HASH') {
            $context = { %$context, %$result };
        } elsif (defined $result) {
            $context = { %$context, result => $result };
        }
    }
    
    return {
        pipeline => \@pipeline_trace,
        final    => $context,
        steps    => scalar @pipeline_trace,
    };
}

# === INCREMENTAL RE-EVALUATION ===

# Build dependency graph: which rules depend on which fact types.
sub _build_dependency_graph {
    my ($self) = @_;
    $self->{rule_deps} = {};
    
    for my $rule ($self->{rules}->@*) {
        next unless $rule->type eq 'production';
        my %deps;
        
        for my $cond (@{$rule->{conditions} // []}) {
            next unless ref $cond eq 'HASH';
            my $cond_type = $cond->{type};
            next unless defined $cond_type;
            $deps{$cond_type} = 1;
        }
        
        $self->{rule_deps}{$rule->name} = [ keys %deps ];
    }
}

    # Re-evaluate only rules that depend on changed fact types.
sub re_evaluate {
    my ($self, $changed_fact_types) = @_;
    $changed_fact_types = [ $changed_fact_types ] unless ref $changed_fact_types eq 'ARRAY';
    
    # Build dependency graph if not already done or rules changed.
    $self->_build_dependency_graph;
    
    # Find rules that depend on changed types.
    my %affected_rules;
    for my $fact_type (@$changed_fact_types) {
        for my $rule_name (keys $self->{rule_deps}->%*) {
            my $deps = $self->{rule_deps}{$rule_name};
            if (grep { $_ eq $fact_type } @$deps) {
                $affected_rules{$rule_name} = 1;
            }
        }
    }
    
    # Re-evaluate affected rules.
    my @re_evaluated;
    for my $rule_name (keys %affected_rules) {
        my $rule = $self->get_rule($rule_name);
        next unless $rule && $rule->enabled;
        
        my $matched = $self->_match_production($rule);
        if ($matched) {
            my $result = $rule->execute({ facts => $self->{facts}, match => $matched->{facts}[0] });
            if (defined $result) {
                my @new_facts = ref $result eq 'ARRAY' ? @$result : ($result);
                for my $nf (@new_facts) {
                    next unless ref $nf eq 'HASH' && $nf->{type};
                    next if $self->_fact_exists($nf->{type}, $nf->{attributes} // {});
                    
                    $self->assert_fact(
                        $nf->{type},
                        $nf->{attributes} // {},
                        { asserted_by => $rule->name },
                    );
                    push @re_evaluated, {
                        rule => $rule_name,
                        fact => $nf->{type},
                    };
                }
            }
        }
    }
    
    return {
        affected     => [ keys %affected_rules ],
        re_evaluated => \@re_evaluated,
        count        => scalar @re_evaluated,
    };
}

1;
