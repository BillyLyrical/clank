# Wit lifecycle (docs/Wits.md §5): disable runs the revertible effects — bus
# subscriptions removed, tools and commands hidden; enable re-registers fresh
# (module wits via register(), declarative decks by replaying their .wit files).
use strict; use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::RealBin/../lib";
use File::Temp qw(tempdir);
use File::Path qw(make_path);

my $tmp = tempdir(CLEANUP => 1);
local $ENV{HOME}      = "$tmp/home";
local $ENV{CLAM_HOME} = "$tmp/clamhome";
delete $ENV{CLAM_WITS_PATH};
chdir $tmp or die "chdir: $!";

use AI::Clam::Store;
use AI::Clam::Bus;
use AI::Clam::Session;
use AI::Clam::PluginManager;

sub write_file {
    my ($path, $content) = @_;
    make_path((do { my $d = $path; $d =~ s{/[^/]+$}{}; $d }));
    open my $fh, '>', $path or die "cannot write $path: $!";
    print {$fh} $content;
    close $fh;
}

my $UROOT = "$ENV{CLAM_HOME}/wits";

# hookwit — module wit with a hook (api->on), a tool, and a command.
write_file("$UROOT/hookwit/wit.toml", <<'EOF');
name="hookwit"
version="0.1.0"
about="Wit fixture with a hook, tool, and command for lifecycle tests"
usage="Test fixture."
EOF
write_file("$UROOT/hookwit/lib/AI/Clam/Wit/Hookwit.pm", <<'EOF');
package AI::Clam::Wit::Hookwit;
use strict; use warnings;
our $FIRED = 0;    # package var: survives re-registration, counts hook fires
sub register {
    my ($self, $api) = @_;
    $api->on('task.ping', sub { our $FIRED++; return { pong => 1 } });
    $api->register_tool(name => 'hook_tool', description => 'x',
        parameters => { type => 'object' }, execute => sub { 'ok' });
    $api->register_command('hookcmd', description => 'fixture command', handler => sub { 'hi' });
}
1;
EOF

# agentdeck — declarative deck with one bus-agent wit.
write_file("$UROOT/agentdeck/deck.toml", <<'EOF');
name="agentdeck"
version="0.1.0"
about="Deck fixture with a bus agent for lifecycle tests"
usage="Test fixture."
wits=["agent.one"]
EOF
write_file("$UROOT/agentdeck/agent/one.wit", <<'EOF');
name="one"
description="bus agent fixture"
subscribes=["task.pong"]
publishes=["result.pong"]
source = <<'PERL'
my ($self, $input, %ctx) = @_;
return { echoed => 1 };
PERL
EOF

# ---------------------------------------------------------------------------
my $store = AI::Clam::Store->new(path => ":memory:");
my $bus   = AI::Clam::Bus->new(store => $store);
my $sess  = AI::Clam::Session->new(store => $store, bus => $bus);
my $pm    = AI::Clam::PluginManager->new;
$pm->bind(bus => $bus, store => $store, session => $sess);

my @wits = $pm->load_all();
is(scalar(@wits), 2, 'both fixtures loaded');
is_deeply($pm->errors, [], 'no load errors');

# (all_tools returns AI::Clam::Tool objects — plain hashrefs; read -> {name})
sub tools_now  { sort map { $_->{name} } $pm->all_tools }
sub cmds_now   { sort keys %{ $pm->all_commands } }

is_deeply([ tools_now ], [ 'agent.one', 'hook_tool' ], 'baseline: both tools visible');
is_deeply([ cmds_now ], ['hookcmd'], 'baseline: command visible');

# Observer for the deck's bus agent output.
my @pong_seen;
$bus->subscribe('result.pong', sub { push @pong_seen, $_[0] });

# --- module wit lifecycle ---------------------------------------------------
$bus->publish('task.ping', {});
is($AI::Clam::Wit::Hookwit::FIRED, 1, 'hook fires while active');

like($pm->disable_wit('hookwit'), qr/^disabled hookwit — 1 hook subscription/, 'disable reports one sub removed');
is($pm->wit_state('hookwit'), 'disabled', 'state is disabled');
$bus->publish('task.ping', {});
is($AI::Clam::Wit::Hookwit::FIRED, 1, 'hook does NOT fire while disabled');
is_deeply([ tools_now ], [ 'agent.one' ], 'tool hidden while disabled');
is_deeply([ cmds_now ], [], 'command hidden while disabled');

like($pm->enable_wit('hookwit'), qr/^enabled hookwit/, 'enable succeeds');
$bus->publish('task.ping', {});
is($AI::Clam::Wit::Hookwit::FIRED, 2, 'hook fires again after enable (fresh closure)');
is_deeply([ tools_now ], [ 'agent.one', 'hook_tool' ], 'tool visible again');

# --- declarative deck lifecycle ---------------------------------------------
$bus->publish('task.pong', {});
is(scalar(@pong_seen), 1, 'deck bus agent fires while active');

like($pm->disable_wit('agentdeck'), qr/^disabled agentdeck — 1 hook subscription/, 'deck disable removes its sub');
$bus->publish('task.pong', {});
is(scalar(@pong_seen), 1, 'deck bus agent silent while disabled');
is_deeply([ tools_now ], [ 'hook_tool' ], 'deck tool hidden while disabled');

like($pm->enable_wit('agentdeck'), qr/^enabled agentdeck/, 'deck enable replays its wits');
$bus->publish('task.pong', {});
is(scalar(@pong_seen), 2, 'deck bus agent fires again after enable');
is_deeply([ tools_now ], [ 'agent.one', 'hook_tool' ], 'deck tool visible again');

# --- edge cases ---------------------------------------------------------------
like($pm->disable_wit('nope'), qr/no such wit/, 'unknown name reported');
$pm->disable_wit('hookwit');
like($pm->disable_wit('hookwit'), qr/already disabled/, 'double disable is a no-op message');
$pm->enable_wit('agentdeck');
like($pm->enable_wit('agentdeck'), qr/already active/, 'double enable is a no-op message');

done_testing();
