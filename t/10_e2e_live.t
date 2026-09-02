# Live end-to-end smoke: drive clamd --stdio against a REAL model server and
# verify multi-query continuity through the full stack (driver -> app -> loop
# -> provider -> HTTP).  Skipped unless CLAM_LIVE_BASE_URL is set, so plain
# `prove t/` stays offline-safe.
#
#   CLAM_LIVE_BASE_URL=http://192.168.1.12:1234/v1 \
#   CLAM_LIVE_MODEL=qwen3.8-27b \
#   [CLAM_LIVE_PROVIDER=lmstudio] prove -l t/10_e2e_live.t
use strict; use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::RealBin/../lib";
use File::Temp qw(tempdir);
use IPC::Open3;
use Symbol 'gensym';
use Clam::Util qw(jencode jdecode);

my $base_url = $ENV{CLAM_LIVE_BASE_URL};
plan skip_all => 'set CLAM_LIVE_BASE_URL (and optionally CLAM_LIVE_MODEL / CLAM_LIVE_PROVIDER) to run the live e2e smoke'
    unless defined $base_url && length $base_url;

my $model    = $ENV{CLAM_LIVE_MODEL} // 'qwen3.8-27b';
my $provider = $ENV{CLAM_LIVE_PROVIDER} // 'lmstudio';

my $tmp = tempdir(CLEANUP => 1);
local $ENV{HOME} = "$tmp/home";       # isolate from user wits/config
delete $ENV{CLAM_WITS_PATH};
chdir $tmp or die "chdir: $!";

# spawn clamd (IPC::Open3 arg order is write-to-child FIRST — see t/09)
my @cmd = ($^X, "$FindBin::RealBin/../bin/clamd", '--stdio',
    '--provider', $provider, '--base_url', $base_url, '--model', $model,
    '--db', "$tmp/live.db", '--timeout', '180');
my ($w, $r);
my $e = gensym;
my $pid = IPC::Open3::open3($w, $r, $e, @cmd) or die "spawn clamd: $!";

sub rpc {
    my ($req, $label, $max_secs) = @_;
    print {$w} jencode($req), "\n";
    local $SIG{ALRM} = sub { die "clamd did not answer '$label' within ${max_secs}s\n" };
    alarm($max_secs // 240);
    my $line = <$r>;
    alarm(0);
    die "no response from clamd ($label)" unless defined $line;
    chomp $line;
    return jdecode($line);
}

END {
    # never leak the child, even on test failure
    if (defined $pid && kill 0, $pid) {
        eval { print {$w} jencode({ id => 999, command => 'shutdown' }), "\n" };
        alarm(5);
        waitpid($pid, 0);
        alarm(0);
    }
}

my $resp = rpc({ id => 1, command => 'ping' }, 'ping', 30);
is_deeply({ ok => $resp->{ok}, pong => $resp->{pong} }, { ok => 1, pong => 1 }, 'live: ping');

$resp = rpc({ id => 2, prompt => 'Reply with exactly one word: CLAM' }, 'prompt-1', 300);
is($resp->{ok}, 1, 'live: first prompt ok');
like(($resp->{response} // ''), qr/CLAM/i, 'live: model answered through full stack');

# multi-query continuity against the real model
$resp = rpc({ id => 3, prompt => 'In your previous reply to me, what single word did you say? Answer with that one word only.' }, 'prompt-2', 300);
is($resp->{ok}, 1, 'live: second prompt ok');
like(($resp->{response} // ''), qr/CLAM/i, 'live: second turn remembered the first (context continuity)');

$resp = rpc({ id => 4, command => 'session_info' }, 'session_info', 30);
cmp_ok($resp->{messages} // 0, '>=', 4, 'live: session_info reflects both turns');
is(ref $resp->{wits}, 'ARRAY', 'live: session_info wits is an arrayref');

$resp = rpc({ id => 5, command => 'shutdown' }, 'shutdown', 30);
is_deeply({ ok => $resp->{ok}, bye => $resp->{bye} }, { ok => 1, bye => 1 }, 'live: shutdown ack');
close $w; close $r;

local $SIG{ALRM} = sub { die "clamd did not exit after shutdown\n" };
alarm(10);
is(waitpid($pid, 0), $pid, 'live: child reaped (no zombie)');
alarm(0);
is($? >> 8, 0, 'live: clean exit code');

done_testing();
