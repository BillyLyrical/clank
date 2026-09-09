use strict; use warnings;
use Test::More;
use lib 'lib';
use File::Temp qw(tempdir);
use Clank::Store;
use Clank::Bus;
use Clank::Session;
use Clank::PluginManager;

my $tmp = tempdir(CLEANUP => 1);

# isolate from real user/project wits
local $ENV{HOME} = "$tmp/home";
delete $ENV{CLANK_WITS_PATH};
chdir $tmp or die "chdir: $!";

# --- standard-layout wit: tool + command + input hook ------------------------
my $hello_dir = "$tmp/wits/hello";
mkdir "$tmp/wits" or die;
mkdir "$hello_dir" or die;
mkdir "$hello_dir/lib" or die;
mkdir "$hello_dir/lib/AI" or die;
mkdir "$hello_dir/lib/Clank" or die;
mkdir "$hello_dir/lib/Clank/Wits" or die;
open my $fh, '>', "$hello_dir/lib/Clank/Wits/Hello.pm" or die;
print {$fh} <<'WIT';
package Clank::Wits::Hello;
use strict; use warnings;
use parent 'Clank::Wit';
sub register {
    my ($self, $api) = @_;
    $api->register_tool(
        name => 'greet',
        description => 'Greet someone',
        parameters => { type => 'object', properties => { who => { type => 'string' } }, required => ['who'] },
        execute => sub { my ($args) = @_; return "hello, $args->{who}!" },
    );
    $api->register_command('hello', description => 'say hi from wit', handler => sub {
        my ($ctx, $args) = @_;
        return "hi from wit (args: $args)";
    });
    $api->on('input', sub {
        my ($ev) = @_;
        return { action => 'transform', text => $ev->{payload}{text} . ' [hello-wit]' };
    });
}
1;
WIT
close $fh;

# --- broken wit: dies in register() ------------------------------------------
my $broken_dir = "$tmp/wits/broken";
mkdir $broken_dir or die;
mkdir "$broken_dir/lib" or die;
mkdir "$broken_dir/lib/AI" or die;
mkdir "$broken_dir/lib/Clank" or die;
mkdir "$broken_dir/lib/Clank/Wit" or die;
open $fh, '>', "$broken_dir/lib/Clank/Wit/Broken.pm" or die;
print {$fh} "package Clank::Wit::Broken;\nuse strict; use warnings;\nsub register { die \"intentional failure\\n\" }\n1;\n";
close $fh;

# --- single-file wit (no lib/, no base class) ---------------------------------
my $loner_dir = "$tmp/wits2/loner";
mkdir "$tmp/wits2" or die;
mkdir $loner_dir or die;
open $fh, '>', "$loner_dir/loner.pm" or die;
print {$fh} <<'WIT';
package Clank::Wit::Loner;
use strict; use warnings;
sub register {
    my ($self, $api) = @_;
    $api->register_tool(
        name => 'loner_ping', description => 'ping', parameters => { type => 'object', properties => {} },
        execute => sub { 'pong' });
}
1;
WIT
close $fh;

# --- load ---------------------------------------------------------------------
my $store = Clank::Store->new(path => ':memory:');
my $bus   = Clank::Bus->new(store => $store);
my $sess  = Clank::Session->new(store => $store, bus => $bus);

my $pm = Clank::PluginManager->new;
$pm->bind(bus => $bus, store => $store, session => $sess);
my @wits = $pm->load_all(extra_paths => ["$tmp/wits", "$tmp/wits2"]);

is(scalar(@wits), 2, 'hello + loner loaded (broken skipped)');
# NOTE: parenthesize the grep list — otherwise it swallows ok()'s description.
my @errs = @{ $pm->errors };
ok((grep { /broken/ && /intentional failure/ } @errs), 'broken wit error recorded');

# tools from wits are runnable Clank::Tool objects
my %by_name = map { $_->{name} => $_ } $pm->all_tools();
ok($by_name{greet},    'greet tool registered');
ok($by_name{loner_ping}, 'single-file wit tool registered');
is($by_name{greet}->run({ who => 'world' })->{output}, 'hello, world!', 'wit tool executes');
is($by_name{loner_ping}->run({})->{output}, 'pong', 'loner tool executes');

# commands merged
my %cmds = %{ $pm->all_commands };
ok($cmds{hello}, 'slash command registered');
is($cmds{hello}{wit}, 'hello', 'command attributed to wit');
my $out = $cmds{hello}{handler}->({ bus => $bus, store => $store, session => $sess }, 'there');
like($out, qr/hi from wit \(args: there\)/, 'command handler runs with ctx+args');

# input hook fires through the bus
my $pub = $bus->publish('input', { text => 'hey', source => 'interactive' });
ok((grep { ref $_ eq 'HASH' && $_->{action} eq 'transform' } @{ $pub->{results} }),
   'wit input handler result captured');

# api accessors work inside register (session/store/bus reachable)
my $api = $pm->api_for('hello');
isa_ok($api, 'Clank::Wit::API');
is($api->bus, $bus, 'api->bus is the app bus');
is($api->store, $store, 'api->store is the app store');

# --- manifest -----------------------------------------------------------------
my $manifest = $pm->manifest;
like($manifest, qr/^CAPABILITIES/, 'manifest starts with CAPABILITIES');
like($manifest, qr/\d+ wits/, 'manifest reports wit count');
like($manifest, qr/\d+ decks/, 'manifest reports deck count');
# The hello wit's tool is 'greet' — deck is derived from the wit name
like($manifest, qr/greet/, 'manifest includes wit tool names');

done_testing();
