#!/usr/bin/env perl
# 37_daemon.t — test clamd daemonization, status/stop, client reconnect.
#
# These tests start a real clamd daemon (with --provider mock), connect to
# its socket, exchange messages, disconnect, reconnect, and verify the
# daemon survives.  Each test uses a unique socket/pidfile to avoid clashes.

use strict;
use warnings;
use FindBin;
use lib "$FindBin::RealBin/../lib";
use Test::More;
use IO::Socket::UNIX;
use File::Temp qw(tempdir);
use AI::Clam::Util qw(jencode jdecode);

my $clamd = "$FindBin::RealBin/../bin/clamd";
my $tmpdir = tempdir(CLEANUP => 1);
my $provider = 'mock';

# Helper: send a JSON line to a socket and read the response line.
sub send_recv {
    my ($sock, $msg) = @_;
    print {$sock} jencode($msg) . "\n";
    my $line = <$sock>;
    return defined $line ? eval { jdecode($line) } : undef;
}

# --- test: daemon starts, writes PID file, responds to commands ---------------

my $socket_path = "$tmpdir/clamd.sock";
my $pidfile     = "$tmpdir/clamd.pid";

my $pid = fork;
die "fork: $!" unless defined $pid;

if ($pid == 0) {
    # Child: exec clamd as daemon.
    exec $^X, $clamd,
        '--provider', $provider,
        '--socket',   $socket_path,
        '--pidfile',  $pidfile,
        '--daemon',
        '--db',       "$tmpdir/test.db";
    die "exec: $!";
}

# Parent: wait for the daemon to start and create the socket.
for (1 .. 30) {
    last if -e $socket_path;
    select(undef, undef, undef, 0.2);
}
ok(-e $socket_path, "daemon created socket");
ok(-e $pidfile,     "daemon created PID file");

# Verify PID file contains a valid PID.
open my $pfh, '<', $pidfile;
my $daemon_pid = <$pfh>;
close $pfh;
chomp $daemon_pid if defined $daemon_pid;
ok(defined $daemon_pid && $daemon_pid =~ /^\d+$/, "PID file has valid PID: $daemon_pid");

# --- test: connect, ping, status, prompt -------------------------------------

my $sock = IO::Socket::UNIX->new(
    Peer => $socket_path,
) or die "connect to $socket_path: $!";
$sock->autoflush(1);

my $r = send_recv($sock, { id => 1, command => 'ping' });
is($r->{ok},  1,  "ping ok");
is($r->{pong}, 1, "ping returned pong");

$r = send_recv($sock, { id => 2, command => 'status' });
is($r->{ok}, 1, "status ok");
is($r->{daemon}, 1, "status reports daemon=1");
ok($r->{pid} > 0, "status reports valid PID");
ok(defined $r->{session_id}, "status reports session_id");

$r = send_recv($sock, { id => 3, prompt => 'hello' });
is($r->{ok}, 1, "prompt ok");
ok(defined $r->{response}, "prompt got response");

# --- test: disconnect, reconnect, send more commands -------------------------
# This is the key test: the daemon survives client disconnect.

close $sock;
select(undef, undef, undef, 0.5);   # give daemon time to clean up select

# Verify daemon is still running.
ok(kill(0, $daemon_pid), "daemon still running after client disconnect");

# Reconnect.
my $sock2 = IO::Socket::UNIX->new(
    Peer => $socket_path,
) or die "reconnect to $socket_path: $!";
$sock2->autoflush(1);

$r = send_recv($sock2, { id => 10, command => 'ping' });
is($r->{ok}, 1, "reconnected ping ok");

$r = send_recv($sock2, { id => 11, prompt => 'still here?' });
is($r->{ok}, 1, "reconnected prompt ok");
ok(defined $r->{response}, "reconnected prompt got response");

$r = send_recv($sock2, { id => 12, command => 'session_info' });
is($r->{ok}, 1, "session_info ok after reconnect");

close $sock2;

# --- test: --stop shuts down daemon -----------------------------------------

# Read the PID from file to use with --stop.
# (We could also kill directly, but let's test the --stop path.)

# Send TERM to daemon directly (simulates --stop without exec).
kill 'TERM', $daemon_pid;
for (1 .. 20) { last unless kill(0, $daemon_pid); select(undef, undef, undef, 0.2) }
ok(!kill(0, $daemon_pid), "daemon stopped by SIGTERM");
ok(!-e $pidfile, "PID file removed after stop");

done_testing;
