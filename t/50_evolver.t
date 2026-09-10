use strict; use warnings;
use Test::More;
use lib 'lib';
use Clank::Store;
use Clank::ProceduralGraph;
use Clank::ProceduralGraph::Evolver;

my $store = Clank::Store->new(path => ':memory:');
my $pg = Clank::ProceduralGraph->new(store => $store);
my $ev = Clank::ProceduralGraph::Evolver->new(pg => $pg, store => $store);
isa_ok($ev, 'Clank::ProceduralGraph::Evolver');

# ---------------------------------------------------------------------------
# Schema
# ---------------------------------------------------------------------------

my $dbh = $ev->dbh;
my @tables = map { $_->[0] } @{$dbh->selectall_arrayref("SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'pg_%'")};
ok(grep { $_ eq 'pg_rejections' } @tables, 'pg_rejections table exists');
ok(grep { $_ eq 'pg_evolution_log' } @tables, 'pg_evolution_log table exists');

# ---------------------------------------------------------------------------
# Graph setup
# ---------------------------------------------------------------------------

$pg->add_node(id => 'start', label => 'Start', node_type => 'state');
$pg->add_node(id => 'check', label => 'Check Cash');
$pg->add_node(id => 'forecast', label => 'Forecast');
$pg->add_node(id => 'decide', label => 'Decide');
$pg->add_edge(source_id => 'start', target_id => 'check', relation => 'LEADS_TO');
$pg->add_edge(source_id => 'check', target_id => 'forecast', relation => 'LEADS_TO');
$pg->add_edge(source_id => 'forecast', target_id => 'decide', relation => 'LEADS_TO');

# ---------------------------------------------------------------------------
# Mock evaluator
# ---------------------------------------------------------------------------

# Simple evaluator: returns success if query contains "ok", failure otherwise
sub mock_evaluator {
    my ($query) = @_;
    my $success = ($query =~ /ok/i) ? 1 : 0;
    return {
        ok        => $success,
        score     => $success ? 1.0 : 0.0,
        trajectory => [
            { action => 'check_cash', tool => 'check_cash' },
            { action => 'forecast',   tool => 'forecast' },
        ],
    };
}

# ---------------------------------------------------------------------------
# run_tasks
# ---------------------------------------------------------------------------

my $tasks = [
    { query => 'do something ok', expected => 'result' },
    { query => 'this will fail',  expected => 'result' },
    { query => 'another ok task', expected => 'result' },
];

my $results = $ev->run_tasks(tasks => $tasks, evaluator => \&mock_evaluator);
is(scalar @$results, 3, 'run_tasks: 3 results');
is($results->[0]{score}, 1.0, 'run_tasks: success scored 1.0');
is($results->[1]{score}, 0.0, 'run_tasks: failure scored 0.0');
is($results->[2]{score}, 1.0, 'run_tasks: success scored 1.0');
is(ref $results->[0]{trajectory}, 'ARRAY', 'run_tasks: trajectory is array');

# ---------------------------------------------------------------------------
# partition
# ---------------------------------------------------------------------------

my $part = $ev->partition($results);
is(scalar @{$part->{successes}}, 2, 'partition: 2 successes');
is(scalar @{$part->{failures}}, 1, 'partition: 1 failure');
is($part->{failures}[0]{query}, 'this will fail', 'partition: correct failure');

# No failures
my $all_ok = [{ score => 1.0, query => 'a' }, { score => 0.9, query => 'b' }];
$part = $ev->partition($all_ok);
is(scalar @{$part->{successes}}, 2, 'partition: all successes');
ok(!exists $part->{failures}, 'partition: no failures key');

# ---------------------------------------------------------------------------
# apply_mutations
# ---------------------------------------------------------------------------

# add_node
my $applied = $ev->apply_mutations([
    { op => 'add_node', node => { id => 'new_node', label => 'New Node', node_type => 'procedure' } },
]);
is(scalar @{$applied->{applied}}, 1, 'apply: add_node applied');
is(scalar @{$applied->{errors}}, 0, 'apply: no errors');
ok($pg->get_node('new_node'), 'apply: node exists in graph');

# add_edge (need source and target to exist)
$applied = $ev->apply_mutations([
    { op => 'add_edge', edge => { source_id => 'decide', target_id => 'new_node', relation => 'LEADS_TO' } },
]);
is(scalar @{$applied->{applied}}, 1, 'apply: add_edge applied');

# delete_edge — use an existing edge (check -> forecast)
my $edge_to_delete = $pg->outgoing('check')->[0]{id};
ok($edge_to_delete, 'found edge to delete');
$applied = $ev->apply_mutations([
    { op => 'delete_edge', edge_id => $edge_to_delete },
]);
is(scalar @{$applied->{applied}}, 1, 'apply: delete_edge applied');
is(scalar @{$pg->outgoing('check')}, 0, 'apply: edge gone');

# revise_edge — use the start -> check edge
my $edge_id = $pg->outgoing('start')->[0]{id};
ok($edge_id, 'found edge to revise');
$applied = $ev->apply_mutations([
    { op => 'revise_edge', edge_id => $edge_id, attributes => { guidance => 'revised guidance' } },
]);
is(scalar @{$applied->{applied}}, 1, 'apply: revise_edge applied');
my $updated_edge = $pg->get_edge($edge_id);
is($updated_edge->{attributes}{guidance}, 'revised guidance', 'apply: edge attributes updated');

# unknown op
$applied = $ev->apply_mutations([{ op => 'bogus' }]);
is(scalar @{$applied->{errors}}, 1, 'apply: unknown op produces error');
like($applied->{errors}[0]{error}, qr/unknown op/, 'apply: error message');

# missing required fields
$applied = $ev->apply_mutations([{ op => 'add_node' }]);
is(scalar @{$applied->{errors}}, 1, 'apply: missing node produces error');

# ---------------------------------------------------------------------------
# validate
# ---------------------------------------------------------------------------

# Build a fresh graph for validation tests
$pg->clear;
$pg->add_node(id => 'start', label => 'Start');
$pg->add_node(id => 'check', label => 'Check');
$pg->add_edge(source_id => 'start', target_id => 'check', relation => 'LEADS_TO');

my $val_tasks = [
    { query => 'ok task 1' },
    { query => 'fail task' },
    { query => 'ok task 2' },
];

my $val = $ev->validate(
    tasks     => $val_tasks,
    evaluator => \&mock_evaluator,
    baseline  => 0.5,
);
is($val->{n}, 3, 'validate: 3 tasks evaluated');
ok($val->{score} > 0, 'validate: score > 0');
is($val->{accepted}, 1, 'validate: accepted (2/3 = 0.67 >= 0.5)');
is($val->{baseline}, 0.5, 'validate: baseline stored');

# Below baseline
$val = $ev->validate(
    tasks     => [{ query => 'fail' }, { query => 'fail' }],
    evaluator => \&mock_evaluator,
    baseline  => 0.9,
);
is($val->{accepted}, 0, 'validate: rejected when below baseline');
is($val->{score}, 0, 'validate: score is 0 for all failures');

# No baseline = accept
$val = $ev->validate(
    tasks     => [{ query => 'fail' }],
    evaluator => \&mock_evaluator,
);
is($val->{accepted}, 1, 'validate: no baseline means accept');

# ---------------------------------------------------------------------------
# log_rejection / get_rejections
# ---------------------------------------------------------------------------

$ev->log_rejection(
    round     => 1,
    mutation  => { mutations => [{ op => 'delete_edge', edge_id => 'e1' }] },
    val_score => 0.4,
    baseline  => 0.7,
    context   => { applied => [] },
);

my $rejections = $ev->get_rejections(round => 1);
is(scalar @$rejections, 1, 'get_rejections: 1 rejection');
is($rejections->[0]{round}, 1, 'get_rejections: round correct');
is($rejections->[0]{val_score}, 0.4, 'get_rejections: val_score correct');
is($rejections->[0]{baseline}, 0.7, 'get_rejections: baseline correct');
is(ref $rejections->[0]{mutation}, 'HASH', 'get_rejections: mutation decoded');

# Get all rejections up to round
$ev->log_rejection(round => 2, mutation => 'test', val_score => 0.3, baseline => 0.5);
$rejections = $ev->get_rejections(round => 2);
is(scalar @$rejections, 2, 'get_rejections: 2 rejections up to round 2');

# Limit
$rejections = $ev->get_rejections(limit => 1);
is(scalar @$rejections, 1, 'get_rejections: limit 1');

# ---------------------------------------------------------------------------
# log_evolution / get_evolution_log
# ---------------------------------------------------------------------------

$ev->log_evolution(
    round       => 1,
    mutation    => { mutations => [] },
    candidate   => { nodes => [], edges => [] },
    train_score => 0.8,
    val_score   => 0.75,
    committed   => 1,
    reason      => 'val_score (0.75) >= baseline',
);

my $log = $ev->get_evolution_log(round => 1);
is(scalar @$log, 1, 'get_evolution_log: 1 entry');
is($log->[0]{round}, 1, 'get_evolution_log: round');
is($log->[0]{train_score}, 0.8, 'get_evolution_log: train_score');
is($log->[0]{val_score}, 0.75, 'get_evolution_log: val_score');
is($log->[0]{committed}, 1, 'get_evolution_log: committed');

# ---------------------------------------------------------------------------
# _parse_mutations
# ---------------------------------------------------------------------------

my $m = $ev->_parse_mutations('{"mutations": [{"op": "add_node", "node": {"id": "x", "label": "X"}}]}');
is(scalar @$m, 1, '_parse_mutations: 1 mutation parsed');
is($m->[0]{op}, 'add_node', '_parse_mutations: correct op');

# Markdown-wrapped JSON
$m = $ev->_parse_mutations('```json
{"mutations": [{"op": "delete_edge", "edge_id": "e1"}]}
```');
is(scalar @$m, 1, '_parse_mutations: handles markdown code block');

# Empty / invalid
$m = $ev->_parse_mutations('');
is(scalar @$m, 0, '_parse_mutations: empty returns []');
$m = $ev->_parse_mutations('not json at all');
is(scalar @$m, 0, '_parse_mutations: invalid json returns []');

# No mutations
$m = $ev->_parse_mutations('{"mutations": []}');
is(scalar @$m, 0, '_parse_mutations: empty mutations array');

# ---------------------------------------------------------------------------
# evolve (full loop, no provider = no mutations proposed)
# ---------------------------------------------------------------------------

$pg->clear;
$pg->add_node(id => 'start', label => 'Start');
$pg->add_node(id => 'check', label => 'Check');
$pg->add_edge(source_id => 'start', target_id => 'check', relation => 'LEADS_TO');

my $ev_result = $ev->evolve(
    train_tasks => [{ query => 'ok task' }, { query => 'fail task' }],
    val_tasks   => [{ query => 'ok task' }],
    evaluator   => \&mock_evaluator,
    max_rounds  => 2,
);
is(scalar @{$ev_result->{rounds}}, 2, 'evolve: ran 2 rounds');
is($ev_result->{rounds}[0]{status}, 'no_mutations', 'evolve: no mutations (no provider)');
is($ev_result->{graph_stats}{nodes}, 2, 'evolve: graph unchanged');

done_testing;
