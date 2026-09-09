use strict; use warnings;
use Test::More;
use lib 'lib';

# Test self-improvement metrics: escalation tracking and automation ratio.

use Clank::Store;
use Clank::Metrics;

# --- setup ---

my $store = Clank::Store->new(db => ':memory:');
my $metrics = Clank::Metrics->new(store => $store);

# --- test 1: initial state — all zeros ---

my $s = $metrics->self_stats;
is($s->{automation_ratio}, 0, 'initial automation ratio is 0');
is($s->{total_calls}, 0, 'initial total calls is 0');
is($s->{escalation}{rule_hit}, 0, 'initial rule_hit is 0');
is($s->{escalation}{llm_fallback}, 0, 'initial llm_fallback is 0');

# --- test 2: simulate escalation hits ---

$metrics->inc('escalation.rule_hit');
$metrics->inc('escalation.rule_hit');
$metrics->inc('escalation.rule_hit');
$metrics->inc('escalation.wm_hit');
$metrics->inc('escalation.engine_hit');

$s = $metrics->self_stats;
is($s->{escalation}{rule_hit}, 3, 'rule_hit counted');
is($s->{escalation}{wm_hit}, 1, 'wm_hit counted');
is($s->{escalation}{engine_hit}, 1, 'engine_hit counted');
is($s->{total_escalated}, 5, 'total_escalated = rule + wm + engine');

# --- test 3: simulate LLM fallbacks ---

$metrics->inc('escalation.llm_fallback');
$metrics->inc('escalation.llm_fallback');
$metrics->inc('escalation.llm_fallback');

$s = $metrics->self_stats;
is($s->{escalation}{llm_fallback}, 3, 'llm_fallback counted');
is($s->{total_calls}, 8, 'total_calls = escalated + fallback');

# --- test 4: automation ratio ---

# 5 escalated / 8 total = 0.625
my $ratio = $s->{automation_ratio};
ok(abs($ratio - 0.625) < 0.001, "automation ratio is 0.625 (got $ratio)");

# --- test 5: crystallized counter ---

$metrics->inc('escalation.crystallized');
$metrics->inc('escalation.crystallized');

$s = $metrics->self_stats;
is($s->{escalation}{crystallized}, 2, 'crystallized counted');

# --- test 6: 100% automation (no LLM calls) ---

my $m2 = Clank::Metrics->new(store => $store);
$metrics->reset;
$metrics->inc('escalation.rule_hit', 10);

$s = $metrics->self_stats;
is($s->{automation_ratio}, 1, '100% automation when no LLM fallbacks');
is($s->{total_calls}, 10, 'total_calls = all escalated');

# --- test 7: 0% automation (all LLM fallbacks) ---

$metrics->reset;
$metrics->inc('escalation.llm_fallback', 10);

$s = $metrics->self_stats;
is($s->{automation_ratio}, 0, '0% automation when all LLM fallbacks');

# --- test 8: persistence across flush ---

$metrics->reset;
$metrics->inc('escalation.rule_hit', 5);
$metrics->inc('escalation.llm_fallback', 3);
$metrics->flush;

# Create new metrics instance from same store (simulates restart).
my $m3 = Clank::Metrics->new(store => $store);
$s = $m3->self_stats;
is($s->{escalation}{rule_hit}, 5, 'rule_hit persisted after flush');
is($s->{escalation}{llm_fallback}, 3, 'llm_fallback persisted after flush');
ok(abs($s->{automation_ratio} - 0.625) < 0.001, 'automation ratio persisted');

# --- test 9: bus handler returns stats ---

require Clank::Bus;
my $bus = Clank::Bus->new(store => $store, sender => 'test');

$metrics->reset;
$metrics->inc('escalation.rule_hit', 7);
$metrics->inc('escalation.llm_fallback', 3);

$bus->subscribe('metrics.self_stats', sub { return $metrics->self_stats });

my $pub = $bus->publish('metrics.self_stats', {});
ok($pub->{results}[0], 'bus handler returned result');
my $bus_stats = $pub->{results}[0];
ok(abs($bus_stats->{automation_ratio} - 0.7) < 0.001, 'bus handler returns correct ratio');
is($bus_stats->{escalation}{rule_hit}, 7, 'bus handler returns rule_hit');

done_testing();
