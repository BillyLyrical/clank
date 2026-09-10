use strict; use warnings;
use Test::More;
use lib 'lib';
use Clank::Store;
use Clank::ProceduralGraph;

my $store = Clank::Store->new(path => ':memory:');
my $pg = Clank::ProceduralGraph->new(store => $store);
isa_ok($pg, 'Clank::ProceduralGraph');

# ---------------------------------------------------------------------------
# Schema initialized
# ---------------------------------------------------------------------------

my $dbh = $pg->dbh;
my @tables = map { $_->[0] } @{$dbh->selectall_arrayref("SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'pg_%'")};
ok(grep { $_ eq 'pg_nodes' } @tables, 'pg_nodes table created');
ok(grep { $_ eq 'pg_edges' } @tables, 'pg_edges table created');
ok(grep { $_ eq 'pg_evolution_log' } @tables, 'pg_evolution_log table created');
ok(grep { $_ eq 'pg_rejections' } @tables, 'pg_rejections table created');

# ---------------------------------------------------------------------------
# Nodes
# ---------------------------------------------------------------------------

my $n1 = $pg->add_node(id => 'start', label => 'Start', description => 'Entry point', node_type => 'state');
ok($n1, 'node created');
is($n1, 'start', 'returned id matches');

my $n2 = $pg->add_node(id => 'check_cash', label => 'Check Cash', description => 'Verify bank balance', node_type => 'procedure');
my $n3 = $pg->add_node(id => 'forecast', label => 'Cash Flow Forecast', description => 'Project runway', node_type => 'procedure');
my $n4 = $pg->add_node(id => 'decide', label => 'Decide Capital', description => 'Financing decision', node_type => 'procedure');
my $n5 = $pg->add_node(id => 'end', label => 'End', description => 'Exit point', node_type => 'state');

# Get
my $got = $pg->get_node('check_cash');
ok($got, 'node retrieved');
is($got->{label}, 'Check Cash', 'node label correct');
is($got->{description}, 'Verify bank balance', 'node description correct');
is($got->{node_type}, 'procedure', 'node type correct');
is_deeply($got->{attributes}, {}, 'empty attributes default');

# Update
$pg->update_node('check_cash', description => 'Verify current bank balance');
$got = $pg->get_node('check_cash');
is($got->{description}, 'Verify current bank balance', 'node updated');

# All nodes
my $all = $pg->all_nodes;
is(scalar @$all, 5, 'all_nodes returns 5');

# Auto-generated ID
my $n6 = $pg->add_node(label => 'Auto Node');
ok($n6, 'auto-generated id');
is(length($n6), 12, 'auto id is 12 chars');

# ---------------------------------------------------------------------------
# Edges
# ---------------------------------------------------------------------------

my $e1 = $pg->add_edge(
    source_id => 'start', target_id => 'check_cash',
    relation => 'LEADS_TO',
    attributes => { condition => 'beginning of cycle', guidance => 'verify balance first' },
);
ok($e1, 'edge created');

my $e2 = $pg->add_edge(
    source_id => 'check_cash', target_id => 'forecast',
    relation => 'LEADS_TO',
    attributes => { guidance => 'project runway for 6 months' },
);

my $e3 = $pg->add_edge(
    source_id => 'forecast', target_id => 'decide',
    relation => 'LEADS_TO',
    attributes => {
        condition => 'after verifying balance and projecting runway',
        guidance => 'assess financing options',
        pitfalls => 'do not decide without market data',
    },
);

my $e4 = $pg->add_edge(
    source_id => 'decide', target_id => 'end',
    relation => 'LEADS_TO',
);

# Get edge
my $got_e = $pg->get_edge($e1);
ok($got_e, 'edge retrieved');
is($got_e->{source_id}, 'start', 'edge source');
is($got_e->{target_id}, 'check_cash', 'edge target');
is($got_e->{relation}, 'LEADS_TO', 'edge relation');
is_deeply($got_e->{attributes}, { condition => 'beginning of cycle', guidance => 'verify balance first' }, 'edge attributes');
is($got_e->{enabled}, 1, 'edge enabled by default');

# Update edge
$pg->update_edge($e3, attributes => { guidance => 'assess options carefully' });
$got_e = $pg->get_edge($e3);
is($got_e->{attributes}{guidance}, 'assess options carefully', 'edge attributes updated');

# Missing source
eval { $pg->add_edge(source_id => 'nonexistent', target_id => 'end', relation => 'X') };
like($@, qr/does not exist/, 'add_edge dies on missing source');

# Missing target
eval { $pg->add_edge(source_id => 'start', target_id => 'nonexistent', relation => 'X') };
like($@, qr/does not exist/, 'add_edge dies on missing target');

# Missing required fields
eval { $pg->add_edge(source_id => 'start', target_id => 'end') };
like($@, qr/requires relation/, 'add_edge dies without relation');

# All edges
my $all_e = $pg->all_edges;
is(scalar @$all_e, 4, 'all_edges returns 4');

# ---------------------------------------------------------------------------
# Graph queries
# ---------------------------------------------------------------------------

# Outgoing
my $out = $pg->outgoing('check_cash');
is(scalar @$out, 1, 'check_cash has 1 outgoing edge');
is($out->[0]{target_id}, 'forecast', 'outgoing target correct');

# Incoming
my $in = $pg->incoming('forecast');
is(scalar @$in, 1, 'forecast has 1 incoming edge');
is($in->[0]{source_id}, 'check_cash', 'incoming source correct');

# Node with multiple outgoing
$pg->add_edge(source_id => 'decide', target_id => 'forecast', relation => 'REVISITS');
$out = $pg->outgoing('decide');
is(scalar @$out, 2, 'decide has 2 outgoing edges');

# ---------------------------------------------------------------------------
# Neighborhood extraction
# ---------------------------------------------------------------------------

my $nh = $pg->neighborhood('start', 2);
ok($nh, 'neighborhood returned');
isa_ok($nh->{node}, 'HASH', 'neighborhood has node');
is($nh->{node}{id}, 'start', 'neighborhood center is start');

# start -> check_cash -> forecast -> decide -> (end + forecast)
# h=2 from start: check_cash, forecast (and their outgoing)
my $nh_edges = $nh->{edges};
ok(scalar @$nh_edges >= 2, 'neighborhood has edges from 2 hops');

# Check that target labels are included
my @target_labels = map { $_->{target_label} } @$nh_edges;
ok(grep { $_ eq 'Check Cash' } @target_labels, 'neighborhood includes target label');

# Nonexistent node
$nh = $pg->neighborhood('nope', 2);
is($nh, undef, 'neighborhood of nonexistent node is undef');

# ---------------------------------------------------------------------------
# Guidance subgraph extraction
# ---------------------------------------------------------------------------

my $sub = $pg->extract_guidance_subgraph('check_cash', 1);
ok($sub, 'guidance subgraph extracted');
is(scalar @$sub, 1, 'check_cash has 1 edge in 1-hop subgraph');
is($sub->[0]{target_id}, 'forecast', 'subgraph points to forecast');

# ---------------------------------------------------------------------------
# Localization
# ---------------------------------------------------------------------------

# Exact match on id
my $loc = $pg->localize('check_cash');
is($loc, 'check_cash', 'localize exact match on id');

# Exact match on label
$loc = $pg->localize('Check Cash');
is($loc, 'check_cash', 'localize exact match on label');

# Fuzzy: action contains node label
$loc = $pg->localize('I need to check_cash the balance');
is($loc, 'check_cash', 'localize fuzzy match (contains id)');

$loc = $pg->localize('Run Cash Flow Forecast now');
is($loc, 'forecast', 'localize fuzzy match (contains label)');

# No match
$loc = $pg->localize('xyzzy');
is($loc, undef, 'localize returns undef for no match');

# Empty/undef
$loc = $pg->localize('');
is($loc, undef, 'localize empty string returns undef');
$loc = $pg->localize(undef);
is($loc, undef, 'localize undef returns undef');

# ---------------------------------------------------------------------------
# Disable/enable edges (soft delete)
# ---------------------------------------------------------------------------

$pg->disable_edge($e4);
$got_e = $pg->get_edge($e4);
is($got_e->{enabled}, 0, 'edge disabled');

$out = $pg->outgoing('decide');
# Should only have the REVISITS edge now (the LEADS_TO to end is disabled)
my @enabled_out = grep { $_->{enabled} } @$out;
is(scalar @enabled_out, 1, 'disabled edge excluded from outgoing');

# All edges still shows disabled ones in all_edges? No — all_edges filters enabled=1
$all_e = $pg->all_edges;
my @found_disabled = grep { $_->{id} eq $e4 } @$all_e;
is(scalar @found_disabled, 0, 'all_edges excludes disabled');

# Re-enable
$pg->enable_edge($e4);
$out = $pg->outgoing('decide');
is(scalar @$out, 2, 're-enabled edge visible again');

# Hard delete
$pg->delete_edge($e4);
$all_e = $pg->all_edges;
is(scalar @$all_e, 4, 'hard delete removes edge (4 remain: e1,e2,e3,e5)');

# Delete node (soft-deletes incident edges)
$pg->delete_node('auto_node');
$got = $pg->get_node('auto_node');
is($got, undef, 'node deleted');
$all = $pg->all_nodes;
is(scalar @$all, 6, 'node count after delete (start,check_cash,forecast,decide,end,auto_node removed)');

# ---------------------------------------------------------------------------
# Serialization
# ---------------------------------------------------------------------------

my $hash = $pg->to_hash;
is(scalar @{$hash->{nodes}}, 6, 'to_hash has 6 nodes');
is(scalar @{$hash->{edges}}, 4, 'to_hash has 4 edges');

# from_hash: clear and reload
my $pg2 = Clank::ProceduralGraph->new(store => $store);
$pg2->from_hash($hash);
is(scalar @{$pg2->all_nodes}, 6, 'from_hash restores 6 nodes');
is(scalar @{$pg2->all_edges}, 4, 'from_hash restores 4 edges');
my $reloaded = $pg2->get_node('check_cash');
is($reloaded->{label}, 'Check Cash', 'from_hash preserves node data');

# ---------------------------------------------------------------------------
# Clear
# ---------------------------------------------------------------------------

$pg2->clear;
is(scalar @{$pg2->all_nodes}, 0, 'clear removes all nodes');
is(scalar @{$pg2->all_edges}, 0, 'clear removes all edges');

# ---------------------------------------------------------------------------
# Stats
# ---------------------------------------------------------------------------

$pg->clear;
$pg->add_node(id => 'a', label => 'A');
$pg->add_node(id => 'b', label => 'B');
$pg->add_edge(source_id => 'a', target_id => 'b', relation => 'X');
my $st = $pg->stats;
is($st->{nodes}, 2, 'stats node count');
is($st->{edges}, 1, 'stats edge count');
is($st->{disabled_edges}, 0, 'stats disabled count');
is($st->{evolution_rounds}, 0, 'stats evolution rounds');

# ---------------------------------------------------------------------------
# Auto-generated node IDs from add_node
# ---------------------------------------------------------------------------

my $auto_id = $pg->add_node(label => 'Generated');
ok($auto_id, 'add_node with auto id');
like($auto_id, qr/^[a-z0-9]{12}$/, 'auto id format');

done_testing;
