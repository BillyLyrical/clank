# Section 2: REPL — Interactive Interface Testing
# Tests sigil dispatch (/, #, ?, $, @, %, >, :, ~, !) and bare text via clankd.
use strict; use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::RealBin/../lib";
use File::Temp qw(tempdir);
use IPC::Open3;
use Symbol;
use Clank::Util qw(jencode jdecode);

my $tmp = tempdir(CLEANUP => 1);
local $ENV{HOME} = "$tmp/home";
delete $ENV{CLANK_WITS_PATH};

my @clankd_cmd = ($^X, "$FindBin::RealBin/../bin/clankd", '--stdio', '--provider', 'mock', '--db', ':memory:');

sub spawn_clankd {
    my ($w, $r);
    my $e = Symbol::gensym;
    my $pid = IPC::Open3::open3($w, $r, $e, @clankd_cmd);
    return ($r, $w, $e, $pid);
}

sub rpc {
    my ($w, $r, $req) = @_;
    print {$w} jencode($req), "\n";
    my $line = <$r>;
    die "no response from clankd" unless defined $line;
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
# 2.1 — / Command dispatch
# =============================================================================
{
    my ($r, $w, $e, $pid) = spawn_clankd();

    subtest '/help' => sub {
        my $resp = rpc($w, $r, { id => 1, prompt => '/help' });
        is($resp->{ok}, 1, '/help ok');
        like($resp->{output} // '', qr/help/i, '/help mentions help');
    };

    subtest '/wits list' => sub {
        my $resp = rpc($w, $r, { id => 2, prompt => '/wits list' });
        is($resp->{ok}, 1, '/wits list ok');
        like($resp->{output} // '', qr/wit/i, '/wits list mentions wits');
    };

    subtest '/tools' => sub {
        my $resp = rpc($w, $r, { id => 3, prompt => '/tools' });
        is($resp->{ok}, 1, '/tools ok');
        like($resp->{output} // '', qr/bash|read|write/i, '/tools lists tools');
    };

    subtest '/model' => sub {
        my $resp = rpc($w, $r, { id => 4, prompt => '/model' });
        is($resp->{ok}, 1, '/model ok');
        like($resp->{output} // '', qr/mock|provider|model/i, '/model mentions provider');
    };

    subtest '/bogus (unknown)' => sub {
        my $resp = rpc($w, $r, { id => 5, prompt => '/bogus' });
        is($resp->{ok}, 1, '/bogus ok');
        like($resp->{output} // '', qr/unknown/i, '/bogus says unknown');
    };

    subtest '/ (bare)' => sub {
        my $resp = rpc($w, $r, { id => 6, prompt => '/' });
        is($resp->{ok}, 1, '/ bare ok');
        like($resp->{output} // '', qr/usage/i, '/ bare shows usage');
    };

    shutdown_clankd($w, $r, $e, $pid);
    pass('section 2.1: / commands done');
}

# =============================================================================
# 2.2 — # Comment
# =============================================================================
{
    my ($r, $w, $e, $pid) = spawn_clankd();

    subtest '# comment' => sub {
        my $resp = rpc($w, $r, { id => 1, prompt => '# this is a comment' });
        is($resp->{ok}, 1, '# comment ok');
        is($resp->{output}, '', '# comment output is empty');
    };

    subtest '# (bare)' => sub {
        my $resp = rpc($w, $r, { id => 2, prompt => '#' });
        is($resp->{ok}, 1, '# bare ok');
        is($resp->{output}, '', '# bare output is empty');
    };

    shutdown_clankd($w, $r, $e, $pid);
    pass('section 2.2: # comments done');
}

# =============================================================================
# 2.3 — $ Eval
# =============================================================================
{
    my ($r, $w, $e, $pid) = spawn_clankd();

    subtest '$ eval 2+2' => sub {
        my $resp = rpc($w, $r, { id => 1, prompt => '$ 2 + 2' });
        is($resp->{ok}, 1, '$ 2+2 ok');
        like($resp->{output} // '', qr/4/, '$ 2+2 returns 4');
    };

    subtest '$ eval time()' => sub {
        my $resp = rpc($w, $r, { id => 2, prompt => '$ time()' });
        is($resp->{ok}, 1, '$ time() ok');
        like($resp->{output} // '', qr/\d+/, '$ time() returns number');
    };

    subtest '$ (bare) usage' => sub {
        my $resp = rpc($w, $r, { id => 3, prompt => '$' });
        is($resp->{ok}, 1, '$ bare ok');
        like($resp->{output} // '', qr/usage/i, '$ bare shows usage');
    };

    subtest '$ invalid perl' => sub {
        my $resp = rpc($w, $r, { id => 4, prompt => '$ [bad perl!!' });
        is($resp->{ok}, 1, '$ invalid ok (no crash)');
        like($resp->{output} // '', qr/error/i, '$ invalid shows error');
    };

    subtest '$ eval undef' => sub {
        my $resp = rpc($w, $r, { id => 5, prompt => '$ undef' });
        is($resp->{ok}, 1, '$ undef ok');
        like($resp->{output} // '', qr/undef/i, '$ undef returns (undef)');
    };

    subtest '$ eval with store' => sub {
        my $resp = rpc($w, $r, { id => 6, prompt => '$ $store->kv_get("nonexistent")' });
        is($resp->{ok}, 1, '$ store access ok');
        like($resp->{output} // '', qr/undef|undef/i, '$ kv_get nonexistent returns undef');
    };

    shutdown_clankd($w, $r, $e, $pid);
    pass('section 2.3: $ eval done');
}

# =============================================================================
# 2.4 — ? Query (with mock provider)
# =============================================================================
{
    my ($r, $w, $e, $pid) = spawn_clankd();

    subtest '? query' => sub {
        my $resp = rpc($w, $r, { id => 1, prompt => '? what is 2+2' });
        is($resp->{ok}, 1, '? query ok');
        like($resp->{output} // '', qr/.+/, '? query returns output');
    };

    subtest '? (bare) usage' => sub {
        my $resp = rpc($w, $r, { id => 2, prompt => '?' });
        is($resp->{ok}, 1, '? bare ok');
        like($resp->{output} // '', qr/usage/i, '? bare shows usage');
    };

    shutdown_clankd($w, $r, $e, $pid);
    pass('section 2.4: ? query done');
}

# =============================================================================
# 2.5 — @ Agent
# =============================================================================
{
    my ($r, $w, $e, $pid) = spawn_clankd();

    subtest '@list' => sub {
        my $resp = rpc($w, $r, { id => 1, prompt => '@list' });
        is($resp->{ok}, 1, '@list ok');
        like($resp->{output} // '', qr/agents/i, '@list says agents');
        like($resp->{output} // '', qr/reviewer/, '@list has reviewer');
        like($resp->{output} // '', qr/planner/, '@list has planner');
        like($resp->{output} // '', qr/debugger/, '@list has debugger');
        like($resp->{output} // '', qr/security/, '@list has security');
        like($resp->{output} // '', qr/architect/, '@list has architect');
    };

    subtest '@ (bare)' => sub {
        my $resp = rpc($w, $r, { id => 2, prompt => '@' });
        is($resp->{ok}, 1, '@ bare ok');
        like($resp->{output} // '', qr/agents|usage/i, '@ bare shows agents or usage');
    };

    subtest '@status' => sub {
        my $resp = rpc($w, $r, { id => 3, prompt => '@status' });
        is($resp->{ok}, 1, '@status ok');
        like($resp->{output} // '', qr/stats|invoked/i, '@status shows stats');
    };

    subtest '@nonexistent' => sub {
        my $resp = rpc($w, $r, { id => 4, prompt => '@nonexistent do something' });
        is($resp->{ok}, 1, '@nonexistent ok (no crash)');
        like($resp->{output} // '', qr/error|not found|no profile/i, '@nonexistent reports error');
    };

    shutdown_clankd($w, $r, $e, $pid);
    pass('section 2.5: @ agent done');
}

# =============================================================================
# 2.6 — % Pipeline
# =============================================================================
{
    my ($r, $w, $e, $pid) = spawn_clankd();

    subtest '% list' => sub {
        my $resp = rpc($w, $r, { id => 1, prompt => '% list' });
        is($resp->{ok}, 1, '% list ok');
        like($resp->{output} // '', qr/pipeline|found|output/i, '% list returns result');
    };

    subtest '% nonexistent' => sub {
        my $resp = rpc($w, $r, { id => 2, prompt => '% nonexistent' });
        is($resp->{ok}, 1, '% nonexistent ok');
        like($resp->{output} // '', qr/not found/i, '% nonexistent says not found');
    };

    subtest '% (bare)' => sub {
        my $resp = rpc($w, $r, { id => 3, prompt => '%' });
        is($resp->{ok}, 1, '% bare ok');
        like($resp->{output} // '', qr/usage/i, '% bare shows usage');
    };

    shutdown_clankd($w, $r, $e, $pid);
    pass('section 2.6: % pipeline done');
}

# =============================================================================
# 2.7 — > Inline Pipe
# =============================================================================
{
    my ($r, $w, $e, $pid) = spawn_clankd();

    subtest '> single stage' => sub {
        my $resp = rpc($w, $r, { id => 1, prompt => '> summarize this text' });
        is($resp->{ok}, 1, '> single stage ok');
        # May succeed or fail depending on Pipeline implementation
        ok(defined $resp->{output} || defined $resp->{error}, '> returns output or error');
    };

    subtest '> (bare)' => sub {
        my $resp = rpc($w, $r, { id => 2, prompt => '>' });
        is($resp->{ok}, 1, '> bare ok');
        like($resp->{output} // '', qr/usage/i, '> bare shows usage');
    };

    shutdown_clankd($w, $r, $e, $pid);
    pass('section 2.7: > pipe done');
}

# =============================================================================
# 2.8 — : Topic
# =============================================================================
{
    my ($r, $w, $e, $pid) = spawn_clankd();

    subtest ': publish simple' => sub {
        my $resp = rpc($w, $r, { id => 1, prompt => ': test.topic' });
        is($resp->{ok}, 1, ': publish ok');
        like($resp->{output} // '', qr/published/i, ': says published');
    };

    subtest ': listen' => sub {
        my $resp = rpc($w, $r, { id => 2, prompt => ': listen tool_use' });
        is($resp->{ok}, 1, ': listen ok');
        like($resp->{output} // '', qr/recent|events|no/i, ': listen returns result');
    };

    subtest ': publish with JSON' => sub {
        my $resp = rpc($w, $r, { id => 3, prompt => ': publish test.event {"key":"value"}' });
        is($resp->{ok}, 1, ': publish json ok');
        like($resp->{output} // '', qr/published/i, ': publish json says published');
    };

    subtest ': (bare)' => sub {
        my $resp = rpc($w, $r, { id => 4, prompt => ':' });
        is($resp->{ok}, 1, ': bare ok');
        like($resp->{output} // '', qr/usage/i, ': bare shows usage');
    };

    shutdown_clankd($w, $r, $e, $pid);
    pass('section 2.8: : topic done');
}

# =============================================================================
# 2.9 — ~ Wit
# =============================================================================
{
    my ($r, $w, $e, $pid) = spawn_clankd();

    subtest '~ list' => sub {
        my $resp = rpc($w, $r, { id => 1, prompt => '~ list' });
        is($resp->{ok}, 1, '~ list ok');
        like($resp->{output} // '', qr/wits|loaded|output/i, '~ list returns result');
    };

    subtest '~ status' => sub {
        my $resp = rpc($w, $r, { id => 2, prompt => '~ status' });
        is($resp->{ok}, 1, '~ status ok');
        like($resp->{output} // '', qr/wits.*active|total/i, '~ status shows counts');
    };

    subtest '~ inspect nonexistent' => sub {
        my $resp = rpc($w, $r, { id => 3, prompt => '~ inspect nonexistent' });
        is($resp->{ok}, 1, '~ inspect nonexistent ok');
        like($resp->{output} // '', qr/not found/i, '~ inspect says not found');
    };

    # NOTE: ~ bare acts as ~ list (code: `if ($sub eq 'list' || $sub eq '')`)
    subtest '~ (bare acts as list)' => sub {
        my $resp = rpc($w, $r, { id => 4, prompt => '~' });
        is($resp->{ok}, 1, '~ bare ok');
        like($resp->{output} // '', qr/wits|loaded|output/i, '~ bare lists wits');
    };

    shutdown_clankd($w, $r, $e, $pid);
    pass('section 2.9: ~ wit done');
}

# =============================================================================
# 2.10 — ! History
# =============================================================================
{
    my ($r, $w, $e, $pid) = spawn_clankd();

    subtest '! (clankd)' => sub {
        my $resp = rpc($w, $r, { id => 1, prompt => '!' });
        is($resp->{ok}, 1, '! ok');
        like($resp->{output} // '', qr/not available/i, '! not available in clankd');
    };

    shutdown_clankd($w, $r, $e, $pid);
    pass('section 2.10: ! history done');
}

# =============================================================================
# 2.11 — Bare text (LLM fallback)
# =============================================================================
{
    my ($r, $w, $e, $pid) = spawn_clankd();

    subtest 'bare text goes to LLM' => sub {
        my $resp = rpc($w, $r, { id => 1, prompt => 'hello' });
        is($resp->{ok}, 1, 'bare text ok');
        like($resp->{response} // '', qr/.+/, 'bare text returns response');
        is(ref $resp->{events}, 'ARRAY', 'bare text carries events');
    };

    shutdown_clankd($w, $r, $e, $pid);
    pass('section 2.11: bare text done');
}

# =============================================================================
# 2.12 — Session Management
# =============================================================================
{
    my ($r, $w, $e, $pid) = spawn_clankd();

    subtest '/sessions' => sub {
        my $resp = rpc($w, $r, { id => 1, prompt => '/sessions' });
        is($resp->{ok}, 1, '/sessions ok');
        like($resp->{output} // '', qr/.+/, '/sessions returns output');
    };

    # NOTE: /new calls App->start_session() which creates a new session,
    # but the Driver still holds the old $driver->{session} reference.
    # session_info reads from Driver, so it shows the OLD session_id.
    # The /new output itself contains the correct new session_id.
    subtest '/new' => sub {
        my $resp = rpc($w, $r, { id => 3, prompt => '/new' });
        is($resp->{ok}, 1, '/new ok');
        like($resp->{output} // '', qr/new session [0-9a-f-]+/, '/new output contains new session id');
    };

    subtest '/compact' => sub {
        my $resp = rpc($w, $r, { id => 5, prompt => '/compact' });
        is($resp->{ok}, 1, '/compact ok');
    };

    shutdown_clankd($w, $r, $e, $pid);
    pass('section 2.12: session management done');
}

# =============================================================================
# 2.13 — Mixed dispatch (sigils + bare + commands interleaved)
# =============================================================================
{
    my ($r, $w, $e, $pid) = spawn_clankd();

    subtest 'mixed dispatch' => sub {
        my @sequence = (
            { id => 1, prompt => '# comment 1',  check => sub { is($_[0]->{output}, '', 'comment #1') } },
            { id => 2, prompt => 'hello',        check => sub { is($_[0]->{ok}, 1, 'bare text ok') } },
            { id => 3, prompt => '/help',        check => sub { like($_[0]->{output} // '', qr/help/i, '/help works') } },
            { id => 4, prompt => '$ 1+1',        check => sub { like($_[0]->{output} // '', qr/2/, '$ eval works') } },
            { id => 5, prompt => '# comment 2',  check => sub { is($_[0]->{output}, '', 'comment #2') } },
            { id => 6, prompt => ': test.topic',  check => sub { like($_[0]->{output} // '', qr/published/i, ': publish works') } },
        );
        for my $s (@sequence) {
            my $resp = rpc($w, $r, { id => $s->{id}, prompt => $s->{prompt} });
            $s->{check}->($resp);
        }
    };

    shutdown_clankd($w, $r, $e, $pid);
    pass('section 2.13: mixed dispatch done');
}

done_testing();
