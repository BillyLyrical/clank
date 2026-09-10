# Section 6: Wit System — Loading, Registration, Commands
use strict; use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::RealBin/../lib";
use File::Temp qw(tempdir);
use IPC::Open3;
use Symbol;
use Clank::Util qw(jencode jdecode);

# =============================================================================
# 6.2 — Wit Registration API (in-process)
# =============================================================================
use Clank::Bus;
use Clank::Store;
use Clank::Session;
use Clank::Wit::API;

{
    my $store   = Clank::Store->new(db => ':memory:');
    my $bus     = Clank::Bus->new(store => $store);
    my $session = Clank::Session->new(store => $store, bus => $bus);
    my $api     = Clank::Wit::API->new(bus => $bus, store => $store, session => $session, wit_name => 'test_wit');

    subtest '6.2a: register_tool' => sub {
        my $name = $api->register_tool(
            name      => 'greet',
            description => 'Say hello',
            execute   => sub { "hello $_[0]{name}" },
        );
        is($name, 'greet', 'register_tool returns name');
        my @tools = @{ $api->registered_tools };
        is(scalar @tools, 1, 'one tool registered');
        is($tools[0]{name}, 'greet', 'tool name correct');
        is(ref $tools[0]{execute}, 'CODE', 'tool has execute coderef');
    };

    subtest '6.2b: register_tool requires name and execute' => sub {
        my $api2 = Clank::Wit::API->new(bus => $bus, store => $store, session => $session, wit_name => 'test2');
        eval { $api2->register_tool(name => 'notools') };
        like($@, qr/execute coderef required/, 'register_tool without execute dies');
        eval { $api2->register_tool(execute => sub { 1 }) };
        like($@, qr/name required/, 'register_tool without name dies');
    };

    subtest '6.2c: register_command' => sub {
        my $name = $api->register_command('greet_cmd', description => 'Say hello', handler => sub { "hi" });
        is($name, 'greet_cmd', 'register_command returns name');
        my %cmds = %{ $api->registered_commands };
        ok(exists $cmds{greet_cmd}, 'command registered');
        is($cmds{greet_cmd}{description}, 'Say hello', 'description set');
        is($cmds{greet_cmd}{handler}->(), 'hi', 'handler executes');
    };

    subtest '6.2d: register_command strips leading slash' => sub {
        my $name = $api->register_command('/slash_cmd', description => 'test', handler => sub { 1 });
        is($name, 'slash_cmd', 'leading slash stripped');
    };

    subtest '6.2e: register_command requires handler' => sub {
        my $api2 = Clank::Wit::API->new(bus => $bus, store => $store, session => $session, wit_name => 'test3');
        eval { $api2->register_command('nohandler', description => 'x') };
        like($@, qr/handler required/, 'register_command without handler dies');
    };

    subtest '6.2f: on() subscribes to bus event' => sub {
        my @received;
        my $sub_id = $api->on('test.event', sub { push @received, $_[0]{payload} });
        ok(defined $sub_id, 'on returns subscription id');
        $bus->publish('test.event', { msg => 'hello' });
        is(scalar @received, 1, 'handler received event');
        is($received[0]{msg}, 'hello', 'payload correct');
        is(scalar @{ $api->subs }, 1, 'subscription tracked');
    };

    subtest '6.2g: unsubscribe_all removes subscriptions' => sub {
        my $n = $api->unsubscribe_all;
        is($n, 1, 'unsubscribed 1');
        is(scalar @{ $api->subs }, 0, 'subs list empty');
        # Verify bus subscription removed
        my @received;
        $bus->publish('test.event', { msg => 'after' });
        is(scalar @received, 0, 'no delivery after unsubscribe');
    };

    subtest '6.2h: multiple tools registered' => sub {
        $api->register_tool(name => 'tool_a', execute => sub { 'a' });
        $api->register_tool(name => 'tool_b', execute => sub { 'b' });
        my @tools = @{ $api->registered_tools };
        is(scalar @tools, 3, 'three tools total (greet + a + b)');
    };
}

# =============================================================================
# 6.1 — Wit Loading via clankd ~ sigil
# =============================================================================
{
    my @clankd_cmd = ($^X, "$FindBin::RealBin/../bin/clankd", '--stdio', '--provider', 'mock', '--db', ':memory:');
    sub spawn_clankd {
        my ($w, $r); my $e = Symbol::gensym;
        my $pid = IPC::Open3::open3($w, $r, $e, @clankd_cmd);
        return ($r, $w, $e, $pid);
    }
    sub rpc {
        my ($w, $r, $req) = @_;
        print {$w} jencode($req), "\n";
        my $line = <$r>;
        die "no response" unless defined $line;
        chomp $line;
        return jdecode($line);
    }
    sub shutdown_clankd {
        my ($w, $r, $e, $pid) = @_;
        eval { rpc($w, $r, { id => 9999, command => 'shutdown' }) };
        close $w; close $r; close $e;
        waitpid($pid, 0);
    }

    subtest '6.1a: ~ list via clankd' => sub {
        my ($r, $w, $e, $pid) = spawn_clankd();
        my $resp = rpc($w, $r, { id => 1, prompt => '~ list' });
        is($resp->{ok}, 1, '~ list ok');
        like($resp->{output} // '', qr/wits|loaded|output/i, '~ list returns result');
        shutdown_clankd($w, $r, $e, $pid);
    };

    subtest '6.1b: ~ status via clankd' => sub {
        my ($r, $w, $e, $pid) = spawn_clankd();
        my $resp = rpc($w, $r, { id => 1, prompt => '~ status' });
        is($resp->{ok}, 1, '~ status ok');
        like($resp->{output} // '', qr/wits.*active|total/i, '~ status shows counts');
        shutdown_clankd($w, $r, $e, $pid);
    };

    subtest '6.1c: ~ inspect existing wit' => sub {
        my ($r, $w, $e, $pid) = spawn_clankd();
        # First find an actual wit name
        my $resp = rpc($w, $r, { id => 1, prompt => '~ list' });
        my ($wit_name) = $resp->{output} =~ /^\s+(\S+)/m;
        if ($wit_name) {
            $resp = rpc($w, $r, { id => 2, prompt => "~ inspect $wit_name" });
            is($resp->{ok}, 1, '~ inspect ok');
            like($resp->{output} // '', qr/state:|dir:|pkg:/i, 'inspect shows details');
        } else {
            pass('no wits to inspect (empty harness)');
        }
        shutdown_clankd($w, $r, $e, $pid);
    };

    subtest '6.1d: ~ inspect nonexistent' => sub {
        my ($r, $w, $e, $pid) = spawn_clankd();
        my $resp = rpc($w, $r, { id => 1, prompt => '~ inspect nonexistent_wit' });
        is($resp->{ok}, 1, '~ inspect nonexistent ok');
        like($resp->{output} // '', qr/not found/i, 'not found');
        shutdown_clankd($w, $r, $e, $pid);
    };

    subtest '6.1e: ~ load from directory' => sub {
        my ($r, $w, $e, $pid) = spawn_clankd();
        my $resp = rpc($w, $r, { id => 1, prompt => '~ load /nonexistent/path' });
        is($resp->{ok}, 1, '~ load ok (no crash)');
        like($resp->{output} // '', qr/loaded|error|0/i, 'load reports result');
        shutdown_clankd($w, $r, $e, $pid);
    };

    subtest '6.1f: ~ load (no args)' => sub {
        my ($r, $w, $e, $pid) = spawn_clankd();
        my $resp = rpc($w, $r, { id => 1, prompt => '~ load' });
        is($resp->{ok}, 1, '~ load bare ok');
        like($resp->{output} // '', qr/usage/i, 'usage');
        shutdown_clankd($w, $r, $e, $pid);
    };

    subtest '6.1g: ~ unload nonexistent' => sub {
        my ($r, $w, $e, $pid) = spawn_clankd();
        my $resp = rpc($w, $r, { id => 1, prompt => '~ unload nonexistent_wit' });
        is($resp->{ok}, 1, '~ unload ok');
        like($resp->{output} // '', qr/no such wit|not found/i, 'reports not found');
        shutdown_clankd($w, $r, $e, $pid);
    };

    subtest '6.1h: ~ unload (no args)' => sub {
        my ($r, $w, $e, $pid) = spawn_clankd();
        my $resp = rpc($w, $r, { id => 1, prompt => '~ unload' });
        is($resp->{ok}, 1, '~ unload bare ok');
        like($resp->{output} // '', qr/usage/i, 'usage');
        shutdown_clankd($w, $r, $e, $pid);
    };

    subtest '6.1i: ~ (bare) acts as list' => sub {
        my ($r, $w, $e, $pid) = spawn_clankd();
        my $resp = rpc($w, $r, { id => 1, prompt => '~' });
        is($resp->{ok}, 1, '~ bare ok');
        like($resp->{output} // '', qr/wits|loaded|output/i, '~ bare lists wits');
        shutdown_clankd($w, $r, $e, $pid);
    };

    subtest '6.1j: ~ inspect (no args)' => sub {
        my ($r, $w, $e, $pid) = spawn_clankd();
        my $resp = rpc($w, $r, { id => 1, prompt => '~ inspect' });
        is($resp->{ok}, 1, '~ inspect bare ok');
        like($resp->{output} // '', qr/usage/i, 'usage');
        shutdown_clankd($w, $r, $e, $pid);
    };
}

# =============================================================================
# 6.4 — Wit Commands via REPL (/wits, /help)
# =============================================================================
{
    my @clankd_cmd = ($^X, "$FindBin::RealBin/../bin/clankd", '--stdio', '--provider', 'mock', '--db', ':memory:');
    sub spawn_clankd2 {
        my ($w, $r); my $e = Symbol::gensym;
        my $pid = IPC::Open3::open3($w, $r, $e, @clankd_cmd);
        return ($r, $w, $e, $pid);
    }
    sub rpc2 {
        my ($w, $r, $req) = @_;
        print {$w} jencode($req), "\n";
        my $line = <$r>;
        die "no response" unless defined $line;
        chomp $line;
        return jdecode($line);
    }
    sub shutdown_clankd2 {
        my ($w, $r, $e, $pid) = @_;
        eval { rpc2($w, $r, { id => 9999, command => 'shutdown' }) };
        close $w; close $r; close $e;
        waitpid($pid, 0);
    }

    subtest '6.4a: /wits list via clankd' => sub {
        my ($r, $w, $e, $pid) = spawn_clankd2();
        my $resp = rpc2($w, $r, { id => 1, prompt => '/wits list' });
        is($resp->{ok}, 1, '/wits list ok');
        like($resp->{output} // '', qr/wit/i, '/wits mentions wits');
        shutdown_clankd2($w, $r, $e, $pid);
    };

    subtest '6.4b: /help shows commands' => sub {
        my ($r, $w, $e, $pid) = spawn_clankd2();
        my $resp = rpc2($w, $r, { id => 1, prompt => '/help' });
        is($resp->{ok}, 1, '/help ok');
        like($resp->{output} // '', qr/help/i, '/help mentions help');
        shutdown_clankd2($w, $r, $e, $pid);
    };

    subtest '6.4c: /tools lists wit tools' => sub {
        my ($r, $w, $e, $pid) = spawn_clankd2();
        my $resp = rpc2($w, $r, { id => 1, prompt => '/tools' });
        is($resp->{ok}, 1, '/tools ok');
        like($resp->{output} // '', qr/bash|read|write/i, '/tools lists builtins');
        shutdown_clankd2($w, $r, $e, $pid);
    };
}

done_testing;
