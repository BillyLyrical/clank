# Section 8: Regression / Edge Cases
use strict; use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::RealBin/../lib";
use File::Temp qw(tempdir);
use IPC::Open3;
use Symbol;
use IO::Socket::UNIX;
use Clank::Util qw(jencode jdecode);

my $tmp = tempdir(CLEANUP => 1);

sub spawn_clankd {
    my (%opts) = @_;
    my @cmd = ($^X, "$FindBin::RealBin/../bin/clankd", '--stdio', '--provider', 'mock', '--db', ':memory:');
    push @cmd, '--socket', $opts{socket} if $opts{socket};
    my ($w, $r); my $e = Symbol::gensym;
    my $pid = IPC::Open3::open3($w, $r, $e, @cmd);
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

# =============================================================================
# 8.1 — Error Handling
# =============================================================================
subtest '8.1a: malformed JSON' => sub {
    my ($r, $w, $e, $pid) = spawn_clankd();
    print {$w} "this is not json\n";
    my $line = <$r>;
    chomp $line;
    my $resp = jdecode($line);
    is($resp->{ok}, 0, 'malformed JSON returns ok=0');
    like($resp->{error} // '', qr/json|parse|invalid/i, 'error message about JSON');
    shutdown_clankd($w, $r, $e, $pid);
};

subtest '8.1b: unknown command' => sub {
    my ($r, $w, $e, $pid) = spawn_clankd();
    my $resp = rpc($w, $r, { id => 1, command => 'bogus_command' });
    is($resp->{ok}, 0, 'unknown command returns ok=0');
    like($resp->{error} // '', qr/unknown|unsupported|command/i, 'error about unknown command');
    shutdown_clankd($w, $r, $e, $pid);
};

subtest '8.1c: invalid Perl eval' => sub {
    my ($r, $w, $e, $pid) = spawn_clankd();
    my $resp = rpc($w, $r, { id => 1, prompt => '$ [bad perl!!' });
    is($resp->{ok}, 1, 'eval error ok (no crash)');
    like($resp->{output} // '', qr/error/i, 'eval error message');
    shutdown_clankd($w, $r, $e, $pid);
};

subtest '8.1d: nonexistent agent spawn' => sub {
    my ($r, $w, $e, $pid) = spawn_clankd();
    my $resp = rpc($w, $r, { id => 1, prompt => '@nonexistent_agent do something' });
    is($resp->{ok}, 1, 'nonexistent agent ok (no crash)');
    like($resp->{output} // '', qr/error|not found|no profile/i, 'error reported');
    shutdown_clankd($w, $r, $e, $pid);
};

subtest '8.1e: missing pipeline blueprint' => sub {
    my ($r, $w, $e, $pid) = spawn_clankd();
    my $resp = rpc($w, $r, { id => 1, prompt => '% this_does_not_exist' });
    is($resp->{ok}, 1, 'missing pipeline ok (no crash)');
    like($resp->{output} // '', qr/not found/i, 'not found message');
    shutdown_clankd($w, $r, $e, $pid);
};

subtest '8.1f: empty prompt' => sub {
    my ($r, $w, $e, $pid) = spawn_clankd();
    my $resp = rpc($w, $r, { id => 1, prompt => '' });
    is($resp->{ok}, 0, 'empty prompt returns ok=0');
    # Empty string prompt: no command field, prompt is empty → falls to default
    like($resp->{error} // '', qr/unknown|missing|command/i, 'error reported');
    # Verify clankd is still alive after the error
    $resp = rpc($w, $r, { id => 2, command => 'ping' });
    is($resp->{pong}, 1, 'clankd still alive after empty prompt');
    shutdown_clankd($w, $r, $e, $pid);
};

subtest '8.1g: very long prompt' => sub {
    my ($r, $w, $e, $pid) = spawn_clankd();
    my $long = 'x' x 50000;
    my $resp = rpc($w, $r, { id => 1, prompt => $long });
    is($resp->{ok}, 1, 'long prompt ok (no crash)');
    shutdown_clankd($w, $r, $e, $pid);
};

subtest '8.1h: unicode prompt' => sub {
    my ($r, $w, $e, $pid) = spawn_clankd();
    my $resp = rpc($w, $r, { id => 1, prompt => "hello \x{2603} \x{1F600}" });
    is($resp->{ok}, 1, 'unicode prompt ok');
    shutdown_clankd($w, $r, $e, $pid);
};

subtest '8.1i: missing required field' => sub {
    my ($r, $w, $e, $pid) = spawn_clankd();
    my $resp = rpc($w, $r, { id => 1 });  # no command, no prompt
    is($resp->{ok}, 0, 'missing field returns ok=0');
    shutdown_clankd($w, $r, $e, $pid);
};

subtest '8.1j: prompt with newlines and quotes' => sub {
    my ($r, $w, $e, $pid) = spawn_clankd();
    my $resp = rpc($w, $r, { id => 1, prompt => "line1\nline2\n\"quoted\"\n'单引号'" });
    is($resp->{ok}, 1, 'multiline+quotes ok');
    shutdown_clankd($w, $r, $e, $pid);
};

# =============================================================================
# 8.2 — State Management
# =============================================================================
subtest '8.2a: session persists across prompts' => sub {
    my ($r, $w, $e, $pid) = spawn_clankd();
    rpc($w, $r, { id => 1, prompt => 'turn one' });
    my $i1 = rpc($w, $r, { id => 2, command => 'session_info' });
    rpc($w, $r, { id => 3, prompt => 'turn two' });
    my $i2 = rpc($w, $r, { id => 4, command => 'session_info' });
    is($i2->{session_id}, $i1->{session_id}, 'session_id stable');
    cmp_ok($i2->{messages}, '>', $i1->{messages}, 'messages grew');
    shutdown_clankd($w, $r, $e, $pid);
};

subtest '8.2b: restart resumes same session' => sub {
    my $db = "$tmp/restart_test.db";
    unlink $db if -e $db;
    my @cmd = ($^X, "$FindBin::RealBin/../bin/clankd", '--stdio', '--provider', 'mock', '--db', $db);
    my ($w, $r); my $e = Symbol::gensym;
    my $pid = IPC::Open3::open3($w, $r, $e, @cmd);

    rpc($w, $r, { id => 1, prompt => 'turn one' });
    my $i1 = rpc($w, $r, { id => 2, command => 'session_info' });
    my $sid = $i1->{session_id};

    my $resp = rpc($w, $r, { id => 3, command => 'restart' });
    is($resp->{ok}, 1, 'restart ok');
    is($resp->{resumed}, 1, 'restart resumed');
    is($resp->{session_id}, $sid, 'restart same session_id');

    rpc($w, $r, { id => 4, prompt => 'turn two' });
    my $i2 = rpc($w, $r, { id => 5, command => 'session_info' });
    cmp_ok($i2->{messages}, '>=', 4, 'history preserved after restart');

    rpc($w, $r, { id => 6, command => 'shutdown' });
    close $w; close $r; close $e;
    waitpid($pid, 0);
    unlink $db if -e $db;
    pass('8.2b: child reaped');
};

subtest '8.2c: restart fresh creates new session' => sub {
    my ($r, $w, $e, $pid) = spawn_clankd();
    rpc($w, $r, { id => 1, prompt => 'old session' });
    my $i1 = rpc($w, $r, { id => 2, command => 'session_info' });

    my $resp = rpc($w, $r, { id => 3, command => 'restart', fresh => 1 });
    is($resp->{ok}, 1, 'restart fresh ok');
    is($resp->{resumed}, 0, 'restart fresh not resumed');
    isnt($resp->{session_id}, $i1->{session_id}, 'restart fresh different session_id');

    shutdown_clankd($w, $r, $e, $pid);
};

subtest '8.2d: /new creates fresh session' => sub {
    my ($r, $w, $e, $pid) = spawn_clankd();
    rpc($w, $r, { id => 1, prompt => 'old' });
    my $resp = rpc($w, $r, { id => 2, prompt => '/new' });
    is($resp->{ok}, 1, '/new ok');
    like($resp->{output} // '', qr/new session/, '/new reports new session');
    shutdown_clankd($w, $r, $e, $pid);
};

# =============================================================================
# 8.3 — Concurrency (socket mode)
# =============================================================================
subtest '8.3a: multiple clients via socket' => sub {
    my $sock_path = "$tmp/test_concurrent.sock";
    unlink $sock_path if -e $sock_path;

    # Start clankd in socket mode
    my @cmd = ($^X, "$FindBin::RealBin/../bin/clankd", '--socket', $sock_path, '--provider', 'mock', '--db', ':memory:');
    my $e = Symbol::gensym;
    my $pid = IPC::Open3::open3(my $devnull, my $errh, $e, @cmd);
    close $devnull;

    # Wait for socket
    my $waited = 0;
    while (!-S $sock_path && $waited < 50) {
        select(undef, undef, undef, 0.1);
        $waited++;
    }
    ok(-S $sock_path, '8.3: socket created');

    # Client 1: connect and ping
    my $c1 = IO::Socket::UNIX->new(Peer => $sock_path) or die "connect c1: $!";
    print {$c1} jencode({ id => 1, command => 'ping' }), "\n";
    my $r1 = <$c1>; chomp $r1;
    my $p1 = jdecode($r1);
    is($p1->{ok}, 1, '8.3: client 1 ping ok');
    is($p1->{pong}, 1, '8.3: client 1 pong');
    close $c1;

    # Client 2: connect and ping (after client 1 disconnected)
    my $c2 = IO::Socket::UNIX->new(Peer => $sock_path) or die "connect c2: $!";
    print {$c2} jencode({ id => 2, command => 'ping' }), "\n";
    my $r2 = <$c2>; chomp $r2;
    my $p2 = jdecode($r2);
    is($p2->{ok}, 1, '8.3: client 2 ping ok');
    is($p2->{pong}, 1, '8.3: client 2 pong');
    close $c2;

    # Shutdown
    my $c3 = IO::Socket::UNIX->new(Peer => $sock_path);
    if ($c3) {
        print {$c3} jencode({ id => 99, command => 'shutdown' }), "\n";
        close $c3;
    }
    close $errh;
    waitpid($pid, 0);
    ok(!-e $sock_path, '8.3: socket removed after shutdown');
};

# =============================================================================
# 8.4 — Resource Cleanup
# =============================================================================
subtest '8.4a: no zombie on stdio EOF' => sub {
    my ($r, $w, $e, $pid) = spawn_clankd();
    my $resp = rpc($w, $r, { id => 1, command => 'ping' });
    is($resp->{pong}, 1, 'child alive');
    close $w; close $r;   # EOF without shutdown
    local $SIG{ALRM} = sub { die "zombie!\n" };
    alarm(10);
    my $got = waitpid($pid, 0);
    alarm(0);
    is($got, $pid, '8.4: child reaped after EOF');
    is($? >> 8, 0, '8.4: exit 0 on EOF');
    close $e;
};

subtest '8.4b: shutdown is clean' => sub {
    my ($r, $w, $e, $pid) = spawn_clankd();
    my $resp = rpc($w, $r, { id => 1, command => 'shutdown' });
    is($resp->{bye}, 1, 'bye received');
    close $w; close $r;
    local $SIG{ALRM} = sub { die "no exit\n" };
    alarm(10);
    my $got = waitpid($pid, 0);
    alarm(0);
    is($got, $pid, '8.4: child reaped after shutdown');
    is($? >> 8, 0, '8.4: exit 0');
    close $e;
};

subtest '8.4c: multiple EOF/reconnect cycles' => sub {
    for my $cycle (1..3) {
        my ($r, $w, $e, $pid) = spawn_clankd();
        my $resp = rpc($w, $r, { id => 1, command => 'ping' });
        is($resp->{pong}, 1, "8.4c: cycle $cycle ping");
        close $w; close $r;
        waitpid($pid, 0);
        is($? >> 8, 0, "8.4c: cycle $cycle exit 0");
        close $e;
    }
};

done_testing;
