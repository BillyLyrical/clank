# Clam::Rules::Engine — pluggable inference over rules. Strategies: first,
# random, probabilistic, all; plus forward chaining (production rules).
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
        my $matched_fact = $self->_match_condition($cond);
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

1;
