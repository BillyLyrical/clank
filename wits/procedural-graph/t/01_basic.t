use strict; use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::RealBin/../lib";
use lib "$FindBin::RealBin/../../lib";
use lib 'lib';

use Clank::Store;

# --- Mock Bus ---
package MockBus;
sub new { bless { subs => [] }, shift }
sub subscribe { my ($self, $topic, $cb) = @_; push @{$self->{subs}}, { topic => $topic, cb => $cb }; return scalar @{$self->{subs}} }
sub unsubscribe { return 1 }
sub publish { return { results => [] } }

# --- Mock API ---
package MockAPI;
sub new {
    my $store = Clank::Store->new(path => ':memory:');
    bless { tools => [], commands => {}, bus => MockBus->new(), store => $store }, shift;
}
sub register_tool { my ($self, %def) = @_; push @{$self->{tools}}, \%def; return $def{name} }
sub register_command { my ($self, $name, %def) = @_; $self->{commands}{$name} = \%def }
sub on { my ($self, $topic, $cb) = @_; $self->{bus}->subscribe($topic, $cb) }
sub track_sub { return 1 }
sub ui { return undef }
sub bus { return $_[0]->{bus} }
sub store { return $_[0]->{store} }
sub session { return undef }
sub wit_name { return 'test' }

package main;

require Clank::ProceduralGraph;
require Clank::Wits::ProceduralGraph;

my $mod = 'Clank::Wits::ProceduralGraph';
can_ok($mod, 'register');

my $api = MockAPI->new();
my $pg;
eval { $pg = $mod->register($api) };
is($@, '', 'register() runs without error');
isa_ok($pg, 'Clank::ProceduralGraph', 'register() returns ProceduralGraph');

# --- Tools registered (8 now) ---
my @tool_names = map { $_->{name} } @{$api->{tools}};
is(scalar @tool_names, 8, '8 tools registered');
ok(grep { $_ eq 'pg_show_graph' } @tool_names, 'pg_show_graph');
ok(grep { $_ eq 'pg_add_node' } @tool_names, 'pg_add_node');
ok(grep { $_ eq 'pg_add_edge' } @tool_names, 'pg_add_edge');
ok(grep { $_ eq 'pg_delete_edge' } @tool_names, 'pg_delete_edge');
ok(grep { $_ eq 'pg_delete_node' } @tool_names, 'pg_delete_node');
ok(grep { $_ eq 'pg_stats' } @tool_names, 'pg_stats');
ok(grep { $_ eq 'pg_reset' } @tool_names, 'pg_reset');
ok(grep { $_ eq 'pg_evolve' } @tool_names, 'pg_evolve');

# --- Command registered ---
ok(exists $api->{commands}{pg}, '/pg command registered');
is($api->{commands}{pg}{description}, 'procedural graph: /pg show|stats|reset|evolve', '/pg description');

# --- Populate graph ---
$pg->add_node(id => 'start', label => 'Start', node_type => 'state');
$pg->add_node(id => 'check', label => 'Check Cash', description => 'Verify balance');
$pg->add_node(id => 'forecast', label => 'Forecast', description => 'Project runway');
$pg->add_edge(source_id => 'start', target_id => 'check', relation => 'LEADS_TO',
    attributes => { guidance => 'verify balance first' });
$pg->add_edge(source_id => 'check', target_id => 'forecast', relation => 'LEADS_TO',
    attributes => { condition => 'after check', guidance => 'project 6 months', pitfalls => 'skip negative check' });

# --- pg_show_graph ---
my $show = (grep { $_->{name} eq 'pg_show_graph' } @{$api->{tools}})[0];
my $r = $show->{execute}->({});
is($r->{nodes}, 3, 'pg_show_graph: 3 nodes');
is($r->{edges}, 2, 'pg_show_graph: 2 edges');
like($r->{graph}, qr/Check Cash/, 'graph has labels');

# --- pg_add_node ---
my $add_n = (grep { $_->{name} eq 'pg_add_node' } @{$api->{tools}})[0];
$r = $add_n->{execute}->({ id => 'decide', label => 'Decide' });
is($r->{ok}, 1, 'pg_add_node ok');

# --- pg_add_edge ---
my $add_e = (grep { $_->{name} eq 'pg_add_edge' } @{$api->{tools}})[0];
$r = $add_e->{execute}->({
    source_id => 'forecast', target_id => 'decide', relation => 'LEADS_TO',
    guidance => 'assess options', pitfalls => 'do not skip',
});
is($r->{ok}, 1, 'pg_add_edge ok');

# --- pg_stats ---
my $stats = (grep { $_->{name} eq 'pg_stats' } @{$api->{tools}})[0];
$r = $stats->{execute}->({});
is($r->{nodes}, 4, 'pg_stats: 4 nodes');
is($r->{edges}, 3, 'pg_stats: 3 edges');

# --- pg_reset ---
my $reset = (grep { $_->{name} eq 'pg_reset' } @{$api->{tools}})[0];
$r = $reset->{execute}->({});
is($r->{ok}, 1, 'pg_reset ok');
is($pg->stats->{nodes}, 0, 'pg_reset: nodes cleared');
is($pg->stats->{edges}, 0, 'pg_reset: edges cleared');

# --- /pg command: stats ---
my $pg_cmd = $api->{commands}{pg}{handler};
my $ctx = { bus => $api->{bus}, store => $api->{store}, session => undef, app => undef };

# Repopulate for command tests
$pg->add_node(id => 'start', label => 'Start');
$pg->add_node(id => 'check', label => 'Check');
$pg->add_edge(source_id => 'start', target_id => 'check', relation => 'LEADS_TO');

my $out = $pg_cmd->($ctx, 'stats');
like($out, qr/Nodes:\s+2/, '/pg stats shows node count');
like($out, qr/Edges:\s+1/, '/pg stats shows edge count');

# --- /pg command: show ---
$out = $pg_cmd->($ctx, 'show');
like($out, qr/NODES/, '/pg show has NODES header');
like($out, qr/EDGES/, '/pg show has EDGES header');
like($out, qr/Start/, '/pg show has Start node');

# --- /pg command: reset ---
$out = $pg_cmd->($ctx, 'reset');
is($out, 'procedural graph cleared', '/pg reset output');
is($pg->stats->{nodes}, 0, '/pg reset cleared graph');

# --- /pg command: unknown ---
$out = $pg_cmd->($ctx, 'bogus');
like($out, qr/unknown subcommand/, '/pg bogus shows error');

# --- /pg command: default (no args) ---
$out = $pg_cmd->($ctx, '');
like($out, qr/NODES|empty/, '/pg with no args shows graph (or empty)');

# --- Bus guidance ---
my @pg_subs = grep { $_->{topic} eq 'context_procedural_guidance' } @{$api->{bus}{subs}};
is(scalar @pg_subs, 1, 'procedural_guidance subscribed');

$pg->add_node(id => 'start', label => 'Start');
$pg->add_node(id => 'check', label => 'Check');
$pg->add_edge(source_id => 'start', target_id => 'check', relation => 'LEADS_TO',
    attributes => { guidance => 'verify balance' });

# 'start' has outgoing edge to 'check' — this gives guidance
$r = $pg_subs[0]{cb}->({ payload => { last_action => 'start', prompt => '' } });
like($r->{guidance}, qr/\[procedural guidance\]/, 'guidance header');
like($r->{guidance}, qr/Active procedure: start/, 'active node identified');
like($r->{guidance}, qr/Check/, 'guidance lists target');

# 'check' has no outgoing edges — no guidance
$r = $pg_subs[0]{cb}->({ payload => { last_action => 'check', prompt => '' } });
is($r->{guidance}, '', 'no guidance for node with no outgoing edges');

$r = $pg_subs[0]{cb}->({ payload => { last_action => 'xyzzy', prompt => '' } });
is($r->{guidance}, '', 'no match returns empty guidance');

# --- pg_evolve tool (no provider = no mutations) ---
$pg->clear;
$pg->add_node(id => 'start', label => 'Start');
$pg->add_edge(source_id => 'start', target_id => 'start', relation => 'SELF');

# pg_evolve requires JSON arrays in args
my $evolve_tool = (grep { $_->{name} eq 'pg_evolve' } @{$api->{tools}})[0];
$r = $evolve_tool->{execute}->({
    train_tasks => '[{"query":"ok task"}]',
    val_tasks   => '[{"query":"ok task"}]',
    max_rounds  => 1,
});
is($r->{ok}, 1, 'pg_evolve runs');
is($r->{rounds}, 1, 'pg_evolve: 1 round');
is($r->{best_score}, 0, 'pg_evolve: no mutations without provider');

# pg_evolve: empty tasks
$r = $evolve_tool->{execute}->({
    train_tasks => '[]',
    val_tasks   => '[]',
});
is($r->{error}, 'train_tasks is empty', 'pg_evolve: empty tasks error');

# pg_evolve: invalid JSON
$r = $evolve_tool->{execute}->({
    train_tasks => 'not json',
    val_tasks   => '[]',
});
is($r->{error}, 'train_tasks must be a JSON array', 'pg_evolve: invalid JSON error');

done_testing;
