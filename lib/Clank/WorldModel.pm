# World model: entities, relations, temporal facts, causal links, beliefs.
# High-level API. Database backend lives in Clank::WorldModel::Data.
package Clank::WorldModel;
use strict;
use warnings;
use Clank::Util qw(now_ms jencode jdecode);
our $AUTOLOAD;

sub new {
    my ($class, %args) = @_;
    my $store = $args{store} or die "Clank::WorldModel requires store";
    require Clank::WorldModel::Data;
    my $data = Clank::WorldModel::Data->new(dbh => $store->dbh);
    my $self = bless { store => $store, dbh => $store->dbh, data => $data }, $class;
    return $self;
}

sub dbh   { $_[0]->{data}->dbh }
sub data  { $_[0]->{data} }

# ---------------------------------------------------------------------------
# Bus integration: respond to knowledge requests from the context pipeline.
# ---------------------------------------------------------------------------

sub register {
    my ($self, $api) = @_;
    $self->{api} = $api;
    $api->on('context.knowledge_request', sub { $self->_on_knowledge_request(@_) });
    return $self;
}

sub _on_knowledge_request {
    my ($self, $ev) = @_;
    my $prompt = $ev->{payload}{prompt} // '';
    return unless length $prompt;

    my @facts;
    my $d = $self->{data};

    # Search entities matching prompt keywords.
    my @keywords = grep { length($_) > 2 } split /\s+/, lc($prompt);
    my %seen_entities;
    for my $keyword (@keywords) {
        my $entities = $d->search_entities($keyword, limit => 5);
        for my $ent (@$entities) {
            next if $seen_entities{$ent->{id}}++;
            my $attrs = ref $ent->{attributes} eq 'HASH' ? $ent->{attributes} : {};
            push @facts, {
                type  => 'entity',
                text  => sprintf("%s (%s): %s",
                    $ent->{name} // $ent->{id},
                    $ent->{type},
                    join(', ', map { "$_=$attrs->{$_}" } sort keys %$attrs)),
            };
        }
    }

    # Get facts for top entities.
    my $count = 0;
    for my $ent (values %seen_entities) {
        last if $count++ >= 5;
        my $facts = $d->query_facts(entity_id => $ent);
        for my $f (@$facts) {
            push @facts, {
                type  => 'fact',
                text  => sprintf("%s: %s (confidence: %.0f%%)",
                    $f->{predicate}, $f->{value} // '', ($f->{confidence} // 1) * 100),
            };
        }
    }

    # Get high-confidence beliefs.
    my $beliefs = $d->query_beliefs(min_confidence => 0.7, limit => 5);
    for my $b (@$beliefs) {
        push @facts, {
            type  => 'belief',
            text  => sprintf("Belief (%.0f%%): %s", $b->{confidence} * 100, $b->{statement}),
        };
    }

    return { facts => \@facts } if @facts;
    return undef;
}

# ---------------------------------------------------------------------------
# Counterfactual queries (orchestration layer, not pure DB)
# ---------------------------------------------------------------------------

# Apply a scenario temporarily within a savepoint, run a query, rollback.
sub counterfactual {
    my ($self, %args) = @_;
    my $scenario = $args{scenario} // [];
    my $query    = $args{query}    // sub { [] };
    my $d = $self->{data};
    my $dbh = $d->dbh;

    my $own_txn = !$dbh->{AutoCommit};
    unless ($own_txn) {
        $dbh->{AutoCommit} = 0;
    }
    $dbh->do('SAVEPOINT cf_' . $d->{_cf_depth}++);
    eval {
        for my $op (@$scenario) {
            $self->_apply_op($op);
        }
    };
    if ($@) {
        my $err = $@;
        $dbh->do('ROLLBACK TO cf_' . --$d->{_cf_depth});
        $dbh->do('RELEASE cf_' . $d->{_cf_depth});
        $dbh->{AutoCommit} = 1 unless $own_txn;
        die "counterfactual scenario failed: $err";
    }

    my @result = eval { $query->($self) };
    my $qerr = $@;
    $dbh->do('ROLLBACK TO cf_' . --$d->{_cf_depth});
    $dbh->do('RELEASE cf_' . $d->{_cf_depth});
    $dbh->{AutoCommit} = 1 unless $own_txn;
    die "counterfactual query failed: $qerr" if $qerr;

    return wantarray ? @result : $result[0];
}

sub counterfactual_diff {
    my ($self, %args) = @_;
    my $scenario  = $args{scenario}  // [];
    my $entity_id = $args{entity_id};
    my $d = $self->{data};

    my @orig_facts    = $entity_id ? @{$d->query_facts(entity_id => $entity_id)} : @{$d->query_facts()};
    my @orig_beliefs  = @{$d->query_beliefs()};
    my @orig_causes;
    if ($entity_id) {
        @orig_causes = (
            @{$d->trace_causes($entity_id)},
            @{$d->predict_effects($entity_id)},
        );
    }

    my $cf = $self->counterfactual(
        scenario => $scenario,
        query    => sub {
            my ($wm) = @_;
            my $f = $entity_id ? $wm->{data}->query_facts(entity_id => $entity_id) : $wm->{data}->query_facts();
            my $b = $wm->{data}->query_beliefs();
            my $c = [];
            if ($entity_id) {
                $c = [ @{$wm->{data}->trace_causes($entity_id)}, @{$wm->{data}->predict_effects($entity_id)} ];
            }
            return { facts => $f, beliefs => $b, causes => $c };
        },
    );

    my $cf_facts   = $cf->{facts}   // [];
    my $cf_beliefs = $cf->{beliefs} // [];

    my %orig_f   = map { $_->{id} => 1 } @orig_facts;
    my %cf_f     = map { $_->{id} => 1 } @$cf_facts;
    my %orig_b   = map { $_->{id} => 1 } @orig_beliefs;
    my %cf_b     = map { $_->{id} => 1 } @$cf_beliefs;

    my @diff;
    for my $f (@$cf_facts) {
        push @diff, { type => 'fact_added', fact => $f } unless $orig_f{$f->{id}};
    }
    for my $f (@orig_facts) {
        push @diff, { type => 'fact_removed', fact => $f } unless $cf_f{$f->{id}};
    }
    for my $b (@$cf_beliefs) {
        push @diff, { type => 'belief_added', belief => $b } unless $orig_b{$b->{id}};
    }
    for my $b (@orig_beliefs) {
        push @diff, { type => 'belief_removed', belief => $b } unless $cf_b{$b->{id}};
    }

    return {
        original       => \@orig_facts,
        counterfactual => $cf_facts,
        diff           => \@diff,
    };
}

sub counterfactual_causes {
    my ($self, %args) = @_;
    my $scenario    = $args{scenario}    // [];
    my $cause_id    = $args{cause_id};
    my $effect_id   = $args{effect_id};

    my ($effects, $causes);
    $self->counterfactual(
        scenario => $scenario,
        query    => sub {
            my ($wm) = @_;
            $effects = $wm->{data}->predict_effects($cause_id) if $cause_id;
            $causes  = $wm->{data}->trace_causes($effect_id)   if $effect_id;
        },
    );

    return $effects if $cause_id;
    return $causes  if $effect_id;
    return [];
}

sub _apply_op {
    my ($self, $op) = @_;
    my $type = $op->{op} // die "counterfactual op requires 'op' field\n";
    my $d = $self->{data};

    if ($type eq 'assert_fact') {
        $d->assert_fact(
            entity_id  => $op->{entity_id},
            predicate  => $op->{predicate},
            value      => $op->{value},
            confidence => $op->{confidence} // 1.0,
            source     => 'counterfactual',
        );
    }
    elsif ($type eq 'retract_fact') {
        my $rows = $d->dbh->do(
            'UPDATE wm_facts SET valid_until = ? WHERE id = ?',
            undef, now_ms(), $op->{fact_id},
        );
        die "retract_fact: fact $op->{fact_id} not found\n" if $rows == 0;
    }
    elsif ($type eq 'add_entity') {
        $d->add_entity(
            id         => $op->{id},
            type       => $op->{type},
            name       => $op->{name},
            attributes => $op->{attributes},
        );
    }
    elsif ($type eq 'remove_entity') {
        $d->dbh->do('DELETE FROM wm_entities WHERE id = ?', undef, $op->{entity_id});
    }
    elsif ($type eq 'add_relation') {
        $d->add_relation(
            source_id  => $op->{source_id},
            target_id  => $op->{target_id},
            type       => $op->{type},
            confidence => $op->{confidence} // 1.0,
        );
    }
    elsif ($type eq 'retract_relation') {
        $d->retract_relation($op->{rel_id});
    }
    elsif ($type eq 'add_cause') {
        $d->add_cause(
            cause_entity  => $op->{cause_entity},
            effect_entity => $op->{effect_entity},
            mechanism     => $op->{mechanism},
            confidence    => $op->{confidence} // 1.0,
        );
    }
    elsif ($type eq 'believe') {
        $d->believe(
            statement  => $op->{statement},
            confidence => $op->{confidence} // 0.5,
            source     => 'counterfactual',
        );
    }
    elsif ($type eq 'supersede_belief') {
        $d->supersede_belief(
            $op->{belief_id},
            statement  => $op->{statement},
            confidence => $op->{confidence} // 0.5,
            source     => 'counterfactual',
        );
    }
    else {
        die "unknown counterfactual op: $type\n";
    }
}

# ---------------------------------------------------------------------------
# Auto-delegation: any method not defined here goes to Data.pm
# ---------------------------------------------------------------------------

sub AUTOLOAD {
    my $self = shift;
    (my $method = $AUTOLOAD) =~ s/.*:://;
    return if $method eq 'DESTROY';
    die "WorldModel has no method '$method'\n" unless $self->{data}->can($method);
    return $self->{data}->$method(@_);
}

# ---------------------------------------------------------------------------
# Backward-compatible wrappers for private functions
# ---------------------------------------------------------------------------

sub _cosine_sim { Clank::WorldModel::Data::_cosine_sim(@_) }
sub _gen_id     { Clank::WorldModel::Data::_gen_id() }

1;
