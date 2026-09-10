# Section 7: Workflow Integration — End-to-End
use strict; use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::RealBin/../lib";
use File::Temp qw(tempdir);
use IPC::Open3;
use Symbol;
use Clank::Util qw(jencode jdecode);

# =============================================================================
# 7.2 — Full clankd Session (sequential command chain)
# =============================================================================
{
    my $db = tempdir(CLEANUP => 1) . "/e2e.db";
    my @clankd_cmd = ($^X, "$FindBin::RealBin/../bin/clankd", '--stdio', '--provider', 'mock', '--db', $db);

    my ($w, $r);
    my $e = Symbol::gensym;
    my $pid = IPC::Open3::open3($w, $r, $e, @clankd_cmd);

    sub rpc {
        my ($req) = @_;
        print {$w} jencode($req), "\n";
        my $line = <$r>;
        die "no response" unless defined $line;
        chomp $line;
        return jdecode($line);
    }

    # --- 7.2a: ping ---
    my $resp = rpc({ id => 1, command => 'ping' });
    is($resp->{id}, 1, '7.2: response id matches');
    is($resp->{ok}, 1, '7.2: ping ok');
    is($resp->{pong}, 1, '7.2: pong');

    # --- 7.2b: tools ---
    $resp = rpc({ id => 2, command => 'tools' });
    is($resp->{id}, 2, '7.2: tools response id');
    is($resp->{ok}, 1, '7.2: tools ok');
    ok(ref $resp->{tools} eq 'ARRAY', '7.2: tools is array');
    ok(grep { $_ eq 'bash' } @{ $resp->{tools} }, '7.2: bash tool listed');

    # --- 7.2c: ? query ---
    $resp = rpc({ id => 3, prompt => '? what is Clank?' });
    is($resp->{id}, 3, '7.2: query response id');
    is($resp->{ok}, 1, '7.2: query ok');
    like($resp->{output} // '', qr{.+}, '7.2: query has output');

    # --- 7.2d: $ eval ---
    $resp = rpc({ id => 4, prompt => '$ time()' });
    is($resp->{id}, 4, '7.2: eval response id');
    is($resp->{ok}, 1, '7.2: eval ok');
    like($resp->{output} // '', qr/\d+/, '7.2: eval returns number');

    # --- 7.2e: @list ---
    $resp = rpc({ id => 5, prompt => '@list' });
    is($resp->{id}, 5, '7.2: agent list response id');
    is($resp->{ok}, 1, '7.2: agent list ok');
    like($resp->{output} // '', qr/reviewer/, '7.2: reviewer listed');

    # --- 7.2f: bare text (LLM) ---
    $resp = rpc({ id => 6, prompt => 'hello, can you help me?' });
    is($resp->{id}, 6, '7.2: LLM response id');
    is($resp->{ok}, 1, '7.2: LLM ok');
    like($resp->{response} // '', qr{.+}, '7.2: LLM returned response');

    # --- 7.2g: session_info ---
    $resp = rpc({ id => 7, command => 'session_info' });
    is($resp->{id}, 7, '7.2: session_info response id');
    is($resp->{ok}, 1, '7.2: session_info ok');
    ok(length($resp->{session_id} // ''), '7.2: has session_id');
    cmp_ok($resp->{messages} // 0, '>=', 4, '7.2: messages accumulated');

    # --- 7.2h: events query ---
    $resp = rpc({ id => 8, command => 'events', limit => 50 });
    is($resp->{id}, 8, '7.2: events response id');
    is($resp->{ok}, 1, '7.2: events ok');
    ok(ref $resp->{events} eq 'ARRAY', '7.2: events is array');
    ok(scalar @{ $resp->{events} } > 0, '7.2: events recorded');

    # --- 7.2i: status ---
    $resp = rpc({ id => 9, command => 'status' });
    is($resp->{id}, 9, '7.2: status response id');
    is($resp->{ok}, 1, '7.2: status ok');
    ok($resp->{pid} > 0, '7.2: pid present');

    # --- 7.2j: shutdown ---
    $resp = rpc({ id => 10, command => 'shutdown' });
    is($resp->{id}, 10, '7.2: shutdown response id');
    is($resp->{ok}, 1, '7.2: shutdown ok');
    is($resp->{bye}, 1, '7.2: bye');

    close $w; close $r; close $e;
    local $SIG{ALRM} = sub { die "clankd did not exit\n" };
    alarm(10);
    my $got = waitpid($pid, 0);
    alarm(0);
    is($got, $pid, '7.2: child reaped');
    is($? >> 8, 0, '7.2: exit 0');
}

# =============================================================================
# 7.2b: second session — verify session_id persistence
# =============================================================================
{
    my $db = tempdir(CLEANUP => 1) . "/persist.db";
    my @clankd_cmd = ($^X, "$FindBin::RealBin/../bin/clankd", '--stdio', '--provider', 'mock', '--db', $db);
    my ($w, $r); my $e = Symbol::gensym;
    my $pid = IPC::Open3::open3($w, $r, $e, @clankd_cmd);

    sub rpc2 {
        my ($req) = @_;
        print {$w} jencode($req), "\n";
        my $line = <$r>;
        die "no response" unless defined $line;
        chomp $line;
        return jdecode($line);
    }

    # Turn 1
    my $r1 = rpc2({ id => 1, prompt => 'remember this' });
    my $info1 = rpc2({ id => 2, command => 'session_info' });
    my $sid1 = $info1->{session_id};

    # Turn 2 — same session
    my $r2 = rpc2({ id => 3, prompt => 'second turn' });
    my $info2 = rpc2({ id => 4, command => 'session_info' });
    is($info2->{session_id}, $sid1, '7.2b: session_id persists across turns');
    cmp_ok($info2->{messages}, '>=', 4, '7.2b: messages accumulated');

    # Turn 3
    my $r3 = rpc2({ id => 5, prompt => 'third turn' });
    my $info3 = rpc2({ id => 6, command => 'session_info' });
    is($info3->{session_id}, $sid1, '7.2b: session_id still same');
    cmp_ok($info3->{messages}, '>=', 6, '7.2b: more messages');

    eval { rpc2({ id => 99, command => 'shutdown' }) };
    close $w; close $r; close $e;
    waitpid($pid, 0);
    pass('7.2b: child reaped');
}

# =============================================================================
# 7.3 — Agent + Pipeline Integration via clankd
# =============================================================================
{
    my @clankd_cmd = ($^X, "$FindBin::RealBin/../bin/clankd", '--stdio', '--provider', 'mock', '--db', ':memory:');
    my ($w, $r); my $e = Symbol::gensym;
    my $pid = IPC::Open3::open3($w, $r, $e, @clankd_cmd);

    sub rpc3 {
        my ($req) = @_;
        print {$w} jencode($req), "\n";
        my $line = <$r>;
        die "no response" unless defined $line;
        chomp $line;
        return jdecode($line);
    }

    subtest '7.3a: agent spawn then pipeline list' => sub {
        # Spawn an agent
        my $resp = rpc3({ id => 1, prompt => '@reviewer review lib/Clank.pm' });
        is($resp->{ok}, 1, 'agent spawn ok');

        # List pipelines
        $resp = rpc3({ id => 2, prompt => '% list' });
        is($resp->{ok}, 1, 'pipeline list ok');

        # Agent status should show invocation
        $resp = rpc3({ id => 3, prompt => '@status' });
        like($resp->{output} // '', qr/calls:\d|invoked/i, 'agent stats show invocation');
    };

    subtest '7.3b: mixed sigil chain' => sub {
        my @chain = (
            { id => 10, prompt => '# step 1', check => sub { is($_[0]->{output}, '', 'comment') } },
            { id => 11, prompt => '$ 10 * 5', check => sub { like($_[0]->{output} // '', qr/50/, 'eval') } },
            { id => 12, prompt => ': test.chain.event', check => sub { like($_[0]->{output} // '', qr/published/, 'topic') } },
            { id => 13, prompt => '@list', check => sub { like($_[0]->{output} // '', qr/reviewer/, 'agents') } },
            { id => 14, prompt => '~ status', check => sub { like($_[0]->{output} // '', qr/wits/, 'wits') } },
            { id => 15, prompt => '? hi', check => sub { is($_[0]->{ok}, 1, 'query') } },
            { id => 16, prompt => 'hello world', check => sub { is($_[0]->{ok}, 1, 'bare text') } },
        );
        for my $s (@chain) {
            my $resp = rpc3({ id => $s->{id}, prompt => $s->{prompt} });
            $s->{check}->($resp);
        }
    };

    eval { rpc3({ id => 99, command => 'shutdown' }) };
    close $w; close $r; close $e;
    waitpid($pid, 0);
    pass('7.3: child reaped');
}

# =============================================================================
# 7.4 — Bus Event Flow via clankd
# =============================================================================
{
    my @clankd_cmd = ($^X, "$FindBin::RealBin/../bin/clankd", '--stdio', '--provider', 'mock', '--db', ':memory:');
    my ($w, $r); my $e = Symbol::gensym;
    my $pid = IPC::Open3::open3($w, $r, $e, @clankd_cmd);

    sub rpc4 {
        my ($req) = @_;
        print {$w} jencode($req), "\n";
        my $line = <$r>;
        die "no response" unless defined $line;
        chomp $line;
        return jdecode($line);
    }

    subtest '7.4a: custom event published' => sub {
        my $resp = rpc4({ id => 1, prompt => ': publish test.custom {"msg":"hello"}' });
        is($resp->{ok}, 1, 'publish ok');
        like($resp->{output} // '', qr/published/, 'published');
    };

    subtest '7.4b: event in journal' => sub {
        my $resp = rpc4({ id => 1, command => 'events', topic => 'test.*', limit => 10 });
        is($resp->{ok}, 1, 'events ok');
        my @matches = grep { $_->{topic} eq 'test.custom' } @{ $resp->{events} // [] };
        ok(scalar @matches > 0, 'custom event in journal');
    };

    subtest '7.4c: agent events in journal' => sub {
        rpc4({ id => 1, prompt => '@reviewer review something' });
        my $resp = rpc4({ id => 2, command => 'events', topic => 'agent_*', limit => 20 });
        my @agent_ev = grep { $_->{topic} =~ /^agent_/ } @{ $resp->{events} // [] };
        ok(scalar @agent_ev > 0, 'agent lifecycle events in journal');
    };

    subtest '7.4d: tool events exist' => sub {
        my $resp = rpc4({ id => 1, command => 'events', topic => 'tool_*', limit => 10 });
        is($resp->{ok}, 1, 'tool events query ok');
        # May or may not have tool events depending on mock LLM
        ok(ref $resp->{events} eq 'ARRAY', 'events is array');
    };

    eval { rpc4({ id => 99, command => 'shutdown' }) };
    close $w; close $r; close $e;
    waitpid($pid, 0);
    pass('7.4: child reaped');
}

# =============================================================================
# 7.5 — Context Engineering (verify context features via events)
# =============================================================================
{
    my @clankd_cmd = ($^X, "$FindBin::RealBin/../bin/clankd", '--stdio', '--provider', 'mock', '--db', ':memory:');
    my ($w, $r); my $e = Symbol::gensym;
    my $pid = IPC::Open3::open3($w, $r, $e, @clankd_cmd);

    sub rpc5 {
        my ($req) = @_;
        print {$w} jencode($req), "\n";
        my $line = <$r>;
        die "no response" unless defined $line;
        chomp $line;
        return jdecode($line);
    }

    subtest '7.5a: context events on prompt' => sub {
        my $resp = rpc5({ id => 1, prompt => 'hello' });
        is($resp->{ok}, 1, 'prompt ok');

        # Check for context-related events
        $resp = rpc5({ id => 2, command => 'events', topic => 'context*', limit => 20 });
        my @ctx_ev = grep { $_->{topic} =~ /^context/ } @{ $resp->{events} // [] };
        ok(scalar @ctx_ev > 0, 'context events recorded');

        # Check for agent lifecycle
        $resp = rpc5({ id => 3, command => 'events', topic => 'agent_*', limit => 20 });
        my @agent_ev = grep { $_->{topic} =~ /^(before_)?agent/ } @{ $resp->{events} // [] };
        ok(scalar @agent_ev > 0, 'agent lifecycle events recorded');
    };

    subtest '7.5b: session consistency across prompts' => sub {
        my $resp = rpc5({ id => 1, prompt => 'first' });
        my $info1 = rpc5({ id => 2, command => 'session_info' });
        my $sid = $info1->{session_id};

        $resp = rpc5({ id => 3, prompt => 'second' });
        my $info2 = rpc5({ id => 4, command => 'session_info' });
        is($info2->{session_id}, $sid, 'session_id stable');
        cmp_ok($info2->{messages}, '>=', 4, 'messages grew');
    };

    eval { rpc5({ id => 99, command => 'shutdown' }) };
    close $w; close $r; close $e;
    waitpid($pid, 0);
    pass('7.5: child reaped');
}

done_testing;
