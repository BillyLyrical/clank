# Clank::Driver + clankd: programmatic multi-query sessions and the NDJSON
# front-end, including child-process teardown (the old clank-sock leaked
# zombies; EOF on stdin must now exit cleanly).
use strict; use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::RealBin/../lib";   # absolute: test chdirs later
use File::Temp qw(tempdir);
use IPC::Open3;
use Clank::Driver;
use Clank::Util qw(jencode jdecode);

my $tmp = tempdir(CLEANUP => 1);
local $ENV{HOME} = "$tmp/home";       # isolate from real user wits/config
delete $ENV{CLANK_WITS_PATH};
chdir $tmp or die "chdir: $!";

# --- scripted provider (same pattern as t/06) ---------------------------------
package ScriptedProvider;
sub new { my ($c, $script) = @_; return bless { script => $script, calls => [] }, $c }
sub chat_payload { my ($s, %a) = @_; return { model => 'mock', messages => $a{messages}, tools => $a{tools} } }
sub post_json {
    my ($s, $path, $payload) = @_;
    push @{ $s->{calls} }, $payload;
    return $s->{script}->($payload, scalar @{ $s->{calls} });
}

package main;

# ===========================================================================
# 1. In-process driver: structured results + event capture
# ===========================================================================
my $provider = ScriptedProvider->new(sub {
    my ($payload, $n) = @_;
    if ($n == 1) {   # ask #1, turn 1: call a tool
        return { choices => [ { finish_reason => 'toolUse', message => {
            content => '', tool_calls => [ { id => 'tc1', type => 'function',
                function => { name => 'write', arguments => '{"path":"out.txt","content":"from driver"}' } },
        ] } } ] };
    }
    if ($n == 2) {   # ask #1, turn 2: final answer
        return { choices => [ { finish_reason => 'stop', message => { content => 'all done' } } ] };
    }
    return { choices => [ { finish_reason => 'stop', message => { content => 'second answer' } } ] };   # ask #2
});

my $d = Clank::Driver->new(provider => $provider, db => ':memory:');
isa_ok($d, 'Clank::Driver');
is($d->started, 0, 'not started yet');
$d->start;
ok($d->started && length($d->session_id), 'started with session id');

my $r1 = $d->ask('first question: write the file');
is($r1->{ok}, 1, 'ask #1 ok');
is($r1->{turns}, 2, 'ask #1 took two provider turns');
is($r1->{response}, 'all done', 'final assistant text extracted');
is_deeply([ map { $_->{name} } @{ $r1->{tools} } ], ['write'], 'tool summary from events');
is($r1->{tools}[0]{isError}, 0, 'tool ran without error');
is($r1->{messages_added}, 4, 'user + assistant(toolcall) + toolResult + assistant(final)');

# event capture: full lifecycle in dispatch order
my @topics = map { $_->{topic} } @{ $r1->{events} };
ok($topics[0] eq 'user_prompt_submit' || $topics[0] eq 'input', 'first captured event is user_prompt_submit or input');
is($topics[-1], 'agent_settled', 'last captured event is agent_settled');
ok((grep { $_ eq 'tool_execution_start' } @topics), 'tool execution events captured');

# ===========================================================================
# 2. Multi-query continuity: ask #2 sees ask #1's full history
# ===========================================================================
my $r2 = $d->ask('second question');
is($r2->{ok}, 1, 'ask #2 ok');
is($r2->{response}, 'second answer', 'ask #2 response');

my $p3 = $provider->{calls}[2];   # provider payload for ask #2
my $serialized = jencode($p3->{messages});
like($serialized, qr/first question/, 'ask #2 context includes ask #1 user message');
like($serialized, qr/all done/,       'ask #2 context includes ask #1 final answer');
cmp_ok(scalar(@{ $p3->{messages} }), '>=', 6, 'full history sent to provider on turn two');

# ===========================================================================
# 3. Input-hook short-circuit (handled)
# ===========================================================================
$d->bus->subscribe('input', sub {
    return { action => 'handled', output => 'intercepted!' } if ($_[0]{payload}{text} // '') eq 'secret';
    return;
}, name => 'test.interceptor');
my $r3 = $d->ask('secret');
is_deeply({ ok => $r3->{ok}, handled => $r3->{handled}, output => $r3->{output} },
          { ok => 1, handled => 1, output => 'intercepted!' }, 'input hook short-circuits ask()');
is($r3->{messages_added}, 0, 'no messages added when handled');

# ===========================================================================
# 4. Driver-level timeout (session survives)
# ===========================================================================
package SlowProvider;
sub new { my ($c, $secs) = @_; return bless { secs => $secs // 5 }, $c }
sub chat_payload { my ($s, %a) = @_; return { model => 'slow', messages => $a{messages} } }
sub post_json {
    select(undef, undef, undef, $_[0]{secs}) if $_[0]{secs};
    return { choices => [ { finish_reason => 'stop', message => { content => 'back online' } } ] };
}

package main;
my $slow = SlowProvider->new(5);
my $d2 = Clank::Driver->new(provider => $slow, db => ':memory:');
$d2->start;
my $rt = $d2->ask('hang', timeout => 0.3);
is($rt->{ok}, 0, 'timed-out ask reports failure');
is($rt->{timed_out}, 1, 'timed_out flag set');
like($rt->{error} // '', qr/timed out/, 'timeout error message');

# session still usable after a timeout (the slow provider is now fast)
$slow->{secs} = 0;
my $rafter = $d2->ask('are you alive?');
is($rafter->{response}, 'back online', 'session usable after timeout');

# ===========================================================================
# 5. Introspection + journal queries
# ===========================================================================
my @ev = @{ $d->events(topic => 'tool_*') };
ok(@ev >= 2, 'journal query returns tool events');
is(ref $ev[0]{payload}, 'HASH', 'journal payloads decoded to hashrefs');
ok((grep { $_->{topic} =~ /^tool_/ } @ev) == scalar(@ev), 'topic filter honored');

my @msgs = @{ $d->messages(limit => 2) };
is(scalar(@msgs), 2, 'messages(limit) returns last N');
like(join(' ', map { ref $_->{content} eq 'HASH' ? ($_->{content}{text} // '') : ($_->{content} // '') } @msgs),
     qr/second answer/, 'latest message is the final one');

ok((grep { $_ eq 'write' } $d->tool_names), 'builtin tools listed');
is_deeply($d->load_errors, [], 'no wit load errors');

# ===========================================================================
# 6. Resume: a new driver continues an earlier session from the db file
# ===========================================================================
my $dbfile = "$tmp/resume.db";
my $pd1 = ScriptedProvider->new(sub {
    return { choices => [ { finish_reason => 'stop', message => { content => 'persisted answer' } } ] };
});
my $d3 = Clank::Driver->new(provider => $pd1, db => $dbfile);
$d3->start;
is($d3->ask('remember this')->{response}, 'persisted answer', 'first session turn');
my ($sid, $count) = ($d3->session_id, scalar @{ $d3->messages });
$d3->close;

my $pd2 = ScriptedProvider->new(sub {
    return { choices => [ { finish_reason => 'stop', message => { content => 'i remember' } } ] };
});
my $d4 = Clank::Driver->new(provider => $pd2, db => $dbfile);
$d4->start(resume => $sid);
is($d4->session_id, $sid, 'resumed same session id');
cmp_ok(scalar(@{ $d4->messages }), '>=', $count, 'history survived the restart');
my $r_resume = $d4->ask('do you remember?');
is($r_resume->{response}, 'i remember', 'resumed session answers new prompts');
my $p_resume = $pd2->{calls}[0];
like(jencode($p_resume->{messages}), qr/remember this/, 'resumed context sent to provider');

# ===========================================================================
# 7. Teardown: close is idempotent; DESTROY cleans up without explicit close
# ===========================================================================
$d4->close;
eval { $d4->close };
is($@, '', 'second close() is a no-op');
{
    my $tmp_driver = Clank::Driver->new(provider => ScriptedProvider->new(sub {
        return { choices => [ { finish_reason => 'stop', message => { content => 'x' } } ] };
    }), db => ':memory:');
    $tmp_driver->start;
}   # DESTROY without close must not warn or die
pass('driver destroyed without explicit close');

# ===========================================================================
# 8. clankd stdio front-end (child process)
# ===========================================================================
my @clankd_cmd = ($^X, "$FindBin::RealBin/../bin/clankd", '--stdio', '--provider', 'mock', '--db', ':memory:');

sub spawn_clankd {
    # IPC::Open3 landmine: its DESCRIPTION says (read, write, other) but the
    # SYNOPSIS and actual behavior are (write-to-child, read-from-child, err) —
    # open2() swaps its args when delegating to _open3, which is why open2's
    # docs look right.  Trust the synopsis; verified empirically on this box.
    # Slot 2 must be an explicit gensym: left undef it silently shares slot 1's
    # handle and the child's stderr would mix into the protocol stream.
    my ($w, $r);
    my $e = Symbol::gensym;
    my $pid;
    eval {
        local $SIG{CHLD} = 'DEFAULT';
        $pid = IPC::Open3::open3($w, $r, $e, @clankd_cmd);
        1;
    } or die "open3 failed: $@";
    return ($r, $w, $e, $pid);   # caller keeps (reader, writer) order
}

sub rpc {
    my ($w, $r, $req) = @_;
    print {$w} jencode($req), "\n";
    my $line = <$r>;
    die "no response from clankd" unless defined $line;
    chomp $line;
    return jdecode($line);
}

sub reap {
    my ($pid, $what) = @_;
    local $SIG{ALRM} = sub { die "clankd did not exit within 10s: $what\n" };
    alarm(10);
    my $got = waitpid($pid, 0);
    alarm(0);
    is($got, $pid, "$what: child reaped");
    return $? >> 8;
}

{
    my ($r, $w, $e, $pid) = spawn_clankd();

    my $resp = rpc($w, $r, { id => 1, command => 'ping' });
    is_deeply({ ok => $resp->{ok}, pong => $resp->{pong}, id => $resp->{id} },
              { ok => 1, pong => 1, id => 1 }, 'clankd ping');

    $resp = rpc($w, $r, { id => 2, prompt => 'hello clank' });
    is($resp->{ok}, 1, 'clankd prompt ok');
    like($resp->{response} // '', qr/mock: hello clank/, 'mock provider echoed through full stack');
    is(ref $resp->{events}, 'ARRAY', 'prompt result carries event stream');
    is(ref $resp->{tools}, 'ARRAY', 'prompt result carries tool summary');

    # multi-query over the wire: second prompt sees the first
    $resp = rpc($w, $r, { id => 3, prompt => 'second turn' });
    like(jencode($resp->{events}), qr/first|hello clank/, 'second turn context includes first (via events)');

    $resp = rpc($w, $r, { id => 4, command => 'session_info' });
    is($resp->{ok}, 1, 'session_info ok');
    ok(length($resp->{session_id} // ''), 'session_info has session id');
    cmp_ok($resp->{messages} // 0, '>=', 4, 'session_info message count reflects both turns');
    is(ref $resp->{wits}, 'ARRAY', 'session_info wits is an arrayref');
    is_deeply($resp->{skipped_wits} // [], [], 'session_info skipped_wits clean when empty');

    $resp = rpc($w, $r, { id => 5, command => 'tools' });
    ok((grep { $_ eq 'bash' } @{ $resp->{tools} }), 'tools lists builtins');
    is(ref $resp->{wits}, 'ARRAY', 'tools lists wits');

    $resp = rpc($w, $r, { id => 6, command => 'events', limit => 100 });
    is($resp->{ok}, 1, 'events query ok');
    cmp_ok(scalar(@{ $resp->{events} }), '>=', 10, 'unfiltered events return the full lifecycle');
    ok((grep { $_->{topic} eq 'input' || $_->{topic} eq 'user_prompt_submit' } @{ $resp->{events} }), 'journal contains input/prompt events');
    ok((grep { $_->{topic} eq 'agent_settled' } @{ $resp->{events} }), 'journal contains agent_settled');

    # the mock provider never calls tools — a filtered query must return only matches
    $resp = rpc($w, $r, { id => 7, command => 'events', topic => 'agent_*', limit => 10 });
    ok(scalar(@{ $resp->{events} }) >= 2, 'topic filter returns agent events');
    is((grep { ($_->{topic} // '') !~ /^agent_/ } @{ $resp->{events} }), 0, 'filter honored over the wire');

    # protocol errors are reported, not fatal
    $resp = rpc($w, $r, { id => 8, command => 'bogus' });
    is($resp->{ok}, 0, 'unknown command reports error');
    print {$w} "this is not json\n";
    my $badline = <$r>; chomp $badline;
    is((jdecode($badline))->{ok}, 0, 'invalid JSON reported as ok=0');

    # explicit shutdown: bye line, then clean exit
    $resp = rpc($w, $r, { id => 9, command => 'shutdown' });
    is_deeply({ ok => $resp->{ok}, bye => $resp->{bye} }, { ok => 1, bye => 1 }, 'shutdown ack');
    close $w; close $r;
    is(reap($pid, 'shutdown'), 0, 'clankd exits 0 after shutdown (no zombie)');
    my $err = do { local $/; <$e> }; close $e;
    like($err // '', qr/stdio transport/, 'child logged startup on stderr');
}

# EOF teardown: parent closes the pipe WITHOUT shutdown — child must still exit.
{
    my ($r, $w, $e, $pid) = spawn_clankd();
    my $resp = rpc($w, $r, { id => 1, command => 'ping' });
    is($resp->{pong}, 1, 'eof-test child alive');
    close $w;   # stdin EOF — the old clank-sock leaked here
    close $r;
    is(reap($pid, 'stdin EOF'), 0, 'clankd exits 0 on stdin EOF (zombie regression)');
    close $e;
}

# ===========================================================================
# 9. clankd restart command (resume + fresh)
# ===========================================================================
{
    my $restart_db = "$tmp/restart_test.db";
    unlink $restart_db if -e $restart_db;
    my @restart_cmd = ($^X, "$FindBin::RealBin/../bin/clankd", '--stdio', '--provider', 'mock', '--db', $restart_db);
    my ($w, $r);
    my $e = Symbol::gensym;
    my $pid = IPC::Open3::open3($w, $r, $e, @restart_cmd);

    eval {
        # Turn 1: establish session
        my $resp = rpc($w, $r, { id => 1, prompt => 'turn one' });
        is($resp->{ok}, 1, 'restart-test: first turn ok');
        my $orig_sid = (rpc($w, $r, { id => 2, command => 'session_info' }))->{session_id};

        # Restart: resume same session
        $resp = rpc($w, $r, { id => 3, command => 'restart' });
        is($resp->{ok}, 1, 'restart: ok');
        is($resp->{resumed}, 1, 'restart: resumed flag');
        is($resp->{session_id}, $orig_sid, 'restart: same session_id');

        # Turn 2 in resumed session
        $resp = rpc($w, $r, { id => 4, prompt => 'turn two' });
        is($resp->{ok}, 1, 'restart: second turn ok');

        # Verify history persisted
        $resp = rpc($w, $r, { id => 5, command => 'session_info' });
        cmp_ok($resp->{messages}, '>=', 4, 'restart: history includes both turns');

        # Restart fresh: new session
        $resp = rpc($w, $r, { id => 6, command => 'restart', fresh => 1 });
        is($resp->{ok}, 1, 'restart fresh: ok');
        is($resp->{resumed}, 0, 'restart fresh: resumed=0');
        isnt($resp->{session_id}, $orig_sid, 'restart fresh: different session_id');

        # Turn 3 in fresh session — history should be clean
        $resp = rpc($w, $r, { id => 7, prompt => 'turn three' });
        is($resp->{ok}, 1, 'restart fresh: turn ok');
        $resp = rpc($w, $r, { id => 8, command => 'session_info' });
        cmp_ok($resp->{messages}, '<=', 4, 'restart fresh: clean history (no old turns)');
    };
    if ($@) {
        fail("restart block died: $@");
    }

    # Shutdown (always, even if tests failed)
    eval { rpc($w, $r, { id => 99, command => 'shutdown' }) };
    close $w; close $r;
    waitpid($pid, 0);
    pass('restart-test: child reaped');
    close $e;
    unlink $restart_db if -e $restart_db;
}
done_testing();
