use strict; use warnings;
use Test::More;
use lib 'lib';
use Clank::Store;
use Clank::WorldModel;

my $store = Clank::Store->new(path => ':memory:');
my $wm = Clank::WorldModel->new(store => $store);
isa_ok($wm, 'Clank::WorldModel');

# ---------------------------------------------------------------------------
# Entities
# ---------------------------------------------------------------------------

my $e1 = $wm->add_entity(type => 'person', name => 'Alice', attributes => { role => 'engineer' });
ok($e1, 'entity created');
my $ent = $wm->get_entity($e1);
is($ent->{name}, 'Alice', 'entity retrieved');
is($ent->{type}, 'person', 'entity type');
is_deeply($ent->{attributes}, { role => 'engineer' }, 'entity attributes');

my $e2 = $wm->add_entity(type => 'person', name => 'Bob', attributes => { role => 'manager' });
my $e3 = $wm->add_entity(type => 'project', name => 'Clank', attributes => { lang => 'Perl' });

my $people = $wm->query_entities(type => 'person');
is(scalar @$people, 2, 'query by type');

my $alice = $wm->query_entities(name => 'Alice');
is(scalar @$alice, 1, 'query by name');
is($alice->[0]{id}, $e1, 'query by name returns correct entity');

# ---------------------------------------------------------------------------
# Relations
# ---------------------------------------------------------------------------

my $r1 = $wm->add_relation(source_id => $e1, target_id => $e3, type => 'works_on');
ok($r1, 'relation created');

my $r2 = $wm->add_relation(source_id => $e2, target_id => $e3, type => 'manages');
my $r3 = $wm->add_relation(source_id => $e1, target_id => $e2, type => 'reports_to');

my $rel = $wm->get_relations(source_id => $e1);
is(scalar @$rel, 2, 'relations from alice');

my $manages = $wm->get_relations(type => 'manages');
is(scalar @$manages, 1, 'relations by type');

$wm->retract_relation($r1);
my $after = $wm->get_relations(source_id => $e1);
is(scalar @$after, 1, 'retracted relation excluded');

# ---------------------------------------------------------------------------
# Facts
# ---------------------------------------------------------------------------

my $f1 = $wm->assert_fact(entity_id => $e1, predicate => 'knows_perl', value => 'true', source => 'observation');
ok($f1, 'fact asserted');

my $f2 = $wm->assert_fact(entity_id => $e3, predicate => 'language', value => 'Perl', source => 'declaration');
my $f3 = $wm->assert_fact(entity_id => $e3, predicate => 'status', value => { active => 1, version => '2.0' });

my $facts = $wm->query_facts(entity_id => $e1);
is(scalar @$facts, 1, 'facts for alice');
is($facts->[0]{value}, 'true', 'fact value');

my $perl_facts = $wm->query_facts(predicate => 'language');
is(scalar @$perl_facts, 1, 'facts by predicate');

my $status = $wm->query_facts(predicate => 'status');
is(ref $status->[0]{value}, 'HASH', 'complex fact value decoded');

$wm->retract_fact($f1);
my $after_facts = $wm->query_facts(entity_id => $e1);
is(scalar @$after_facts, 0, 'retracted fact excluded');

# ---------------------------------------------------------------------------
# Causes
# ---------------------------------------------------------------------------

my $c1 = $wm->add_cause(cause_entity => $e1, effect_entity => $e3,
    mechanism => 'alice writes code for clank', confidence => 0.9);
ok($c1, 'cause added');

my $causes = $wm->trace_causes($e3);
is(scalar @$causes, 1, 'trace causes');
is($causes->[0]{cause_entity}, $e1, 'cause entity correct');

my $effects = $wm->predict_effects($e1);
is(scalar @$effects, 1, 'predict effects');
is($effects->[0]{effect_entity}, $e3, 'effect entity correct');

# ---------------------------------------------------------------------------
# Beliefs
# ---------------------------------------------------------------------------

my $b1 = $wm->believe(statement => 'Clank will be the best Perl AI harness',
    confidence => 0.8, source => 'llm');
ok($b1, 'belief created');

my $b2 = $wm->believe(statement => 'Perl is the best language for AI',
    confidence => 0.6, source => 'user');

my $beliefs = $wm->query_beliefs(min_confidence => 0.7);
is(scalar @$beliefs, 1, 'beliefs by confidence');
is($beliefs->[0]{id}, $b1, 'higher confidence belief returned');

my $all_beliefs = $wm->query_beliefs();
is(scalar @$all_beliefs, 2, 'all beliefs');

$wm->supersede_belief($b1, statement => 'Clank may be competitive',
    confidence => 0.5, source => 'rule');
my $after_beliefs = $wm->query_beliefs();
is(scalar @$after_beliefs, 2, 'superseded belief excluded, new belief added');

# ---------------------------------------------------------------------------
# Context generation
# ---------------------------------------------------------------------------

# Add a fact for Alice that won't be retracted
$wm->assert_fact(entity_id => $e1, predicate => 'email', value => 'alice@example.com', source => 'user');

my $ctx = $wm->to_context('Alice works on Clank');
like($ctx, qr/World model/, 'context has header');
like($ctx, qr/Alice/, 'context mentions alice');
like($ctx, qr/Clank/, 'context mentions clank');

# ---------------------------------------------------------------------------
# FTS5 search
# ---------------------------------------------------------------------------

SKIP: {
    skip 'FTS5 not available', 7 unless $wm->has_fts;

    my $found = $wm->search_entities('Alice');
    ok(@$found >= 1, 'search_entities finds alice');
    is($found->[0]{name}, 'Alice', 'search_entities returns correct entity');

    $found = $wm->search_entities('engineer');
    ok(@$found >= 1, 'search_entities finds by attribute');

    my $beliefs = $wm->search_beliefs('competitive');
    ok(@$beliefs >= 1, 'search_beliefs finds by statement');

    $beliefs = $wm->search_beliefs('competitive', min_confidence => 0.7);
    is(scalar @$beliefs, 0, 'search_beliefs respects confidence filter');

    my $facts = $wm->search_facts('email');
    ok(@$facts >= 1, 'search_facts finds by value');

    my $all = $wm->search_all('Alice');
    ok(exists $all->{entities}, 'search_all returns entities');
}

# ---------------------------------------------------------------------------
# Temporal range queries
# ---------------------------------------------------------------------------

use Clank::Util qw(now_ms);

my $t0 = now_ms();

# Create facts at different times
my $f_before = $wm->assert_fact(entity_id => $e1, predicate => 'status',
    value => 'junior', source => 'hr', confidence => 0.9);
# Simulate time passing by updating valid_from directly
$wm->{dbh}->do('UPDATE wm_facts SET valid_from = ? WHERE id = ?', undef, $t0 - 10000, $f_before);

my $f_current = $wm->assert_fact(entity_id => $e1, predicate => 'status',
    value => 'senior', source => 'hr', confidence => 1.0);

# Retract the old fact
$wm->retract_fact($f_before);

# facts_temporal: query facts valid at a specific time
my $past_facts = $wm->facts_at_time($t0 - 5000, entity_id => $e1, predicate => 'status');
is(scalar @$past_facts, 1, 'facts_at_time in past');
is($past_facts->[0]{value}, 'junior', 'facts_at_time returns past value');

my $current_facts = $wm->facts_at_time($t0 + 5000, entity_id => $e1, predicate => 'status');
is(scalar @$current_facts, 1, 'facts_at_time in present');
is($current_facts->[0]{value}, 'senior', 'facts_at_time returns current value');

# facts_temporal with range
my $range_facts = $wm->facts_temporal(
    entity_id => $e1,
    predicate => 'status',
    from_time => $t0 - 10000,
    to_time   => $t0,
);
is(scalar @$range_facts, 1, 'facts_temporal with range');

# fact_history: all facts including retracted
my $history = $wm->fact_history(entity_id => $e1, predicate => 'status');
is(scalar @$history, 2, 'fact_history includes retracted facts');

# Belief temporal queries
my $b_old = $wm->believe(statement => 'Alice is junior',
    confidence => 0.6, source => 'observation');
$wm->{dbh}->do('UPDATE wm_beliefs SET created_at = ? WHERE id = ?', undef, $t0 - 10000, $b_old);

my $b_new = $wm->believe(statement => 'Alice is senior',
    confidence => 0.9, source => 'promotion');
$wm->supersede_belief($b_old, statement => 'Alice was junior',
    confidence => 0.4, source => 'historical');

# beliefs_at_time: what was believed at a specific time
my $past_beliefs = $wm->beliefs_at_time($t0 - 5000);
ok(scalar @$past_beliefs >= 1, 'beliefs_at_time in past');
my @past_alice = grep { $_->{statement} =~ /Alice/ } @$past_beliefs;
ok(scalar @past_alice >= 1, 'beliefs_at_time includes old alice belief');

my $current_beliefs = $wm->beliefs_at_time($t0 + 5000);
my @current_alice = grep { $_->{statement} =~ /Alice is senior/ } @$current_beliefs;
is(scalar @current_alice, 1, 'beliefs_at_time in present has current belief');

# belief_history: full lineage
my $lineage = $wm->belief_lineage($b_new);
ok(scalar @$lineage >= 1, 'belief_lineage returns chain');

# belief_history: all beliefs including superseded
my $all_history = $wm->belief_history(statement_like => 'Alice');
is(scalar @$all_history, 3, 'belief_history includes superseded');

done_testing();
