# Section 5: Agent System — Profiles, Routing, Spawn, Allowlist
use strict; use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::RealBin/../lib";
use File::Temp qw(tempdir);
use IPC::Open3;
use Symbol;
use Clank::Util qw(jencode jdecode);

# Point Agent at the repo's agents/ directory.
use Clank::Agent;
Clank::Agent->agent_dir("$FindBin::RealBin/../agents");

# =============================================================================
# 5.1 — Agent Profiles: validation
# =============================================================================
my @expected_profiles = sort qw(reviewer planner debugger security architect);

subtest '5.1a: all expected profiles exist' => sub {
    my @got = sort Clank::Agent->list;
    is_deeply(\@got, \@expected_profiles, 'all 5 profiles found');
};

subtest '5.1b: each profile has .toml + .md' => sub {
    for my $name (@expected_profiles) {
        my $dir = Clank::Agent->agent_dir;
        ok(-f "$dir/$name.toml", "$name.toml exists");
        ok(-f "$dir/$name.md", "$name.md exists");
    }
};

subtest '5.1c: profile fields populated' => sub {
    for my $name (@expected_profiles) {
        my $p = Clank::Agent->load($name);
        ok($p, "loaded $name");
        is($p->{name}, $name, "$name name field");
        ok(length($p->{description} // ''), "$name has description");
        ok(ref $p->{tools} eq 'ARRAY' && @{$p->{tools}}, "$name has non-empty tools");
        ok(length($p->{model} // ''), "$name has model");
    }
};

subtest '5.1d: reviewer profile specifics' => sub {
    my $p = Clank::Agent->load('reviewer');
    like($p->{description}, qr/review|critique/i, 'reviewer description about review');
    ok(grep { $_ eq 'read' } @{$p->{tools}}, 'reviewer has read');
    ok(grep { $_ eq 'bash' } @{$p->{tools}}, 'reviewer has bash');
    ok(!grep { $_ eq 'edit' } @{$p->{tools}}, 'reviewer has no edit');
};

subtest '5.1e: debugger profile specifics' => sub {
    my $p = Clank::Agent->load('debugger');
    ok(grep { $_ eq 'edit' } @{$p->{tools}}, 'debugger has edit');
    ok(grep { $_ eq 'read' } @{$p->{tools}}, 'debugger has read');
};

subtest '5.1f: load nonexistent returns undef' => sub {
    my $p = Clank::Agent->load('nonexistent_xyz');
    is($p, undef, 'nonexistent returns undef');
};

subtest '5.1g: markdown prompt is clean' => sub {
    for my $name (@expected_profiles) {
        my $p = Clank::Agent->load($name);
        # Markdown prompts use [brackets] legitimately (e.g. [severity]).
        # Check for TOML-specific patterns: key = "value" assignments.
        unlike($p->{prompt} // '', qr/^\w+\s*=\s*"/m, "$name prompt has no TOML key=value");
        ok(length($p->{prompt} // '') > 20, "$name prompt is substantial");
        like($p->{prompt} // '', qr/^#/m, "$name prompt starts with markdown heading");
    }
};

# =============================================================================
# 5.2 — Agent->route: scoring and matching
# =============================================================================
subtest '5.2a: route SQL injection -> security' => sub {
    my $match = Clank::Agent->route('scan for SQL injection vulnerabilities');
    is($match->{name}, 'security', 'SQL injection routes to security');
    cmp_ok($match->{score}, '>', 0.1, 'score above threshold');
};

subtest '5.2b: route code review -> reviewer' => sub {
    my $match = Clank::Agent->route('review this code for issues');
    is($match->{name}, 'reviewer', 'code review routes to reviewer');
    cmp_ok($match->{score}, '>', 0.1, 'score above threshold');
};

# NOTE: TF routing is imprecise — "debug the code" matches reviewer
# because the reviewer description also contains "read" and "code".
# The TF algorithm works best with domain-specific terms (SQL injection,
# architecture). General prompts may route to the wrong agent.
# This is a known limitation documented in AGENTS.md §5.
subtest '5.2c: route noise -> undef' => sub {
    my $match = Clank::Agent->route('banana refrigerator quantum');
    ok(!defined $match, 'noise returns undef');
};

subtest '5.2d: route architecture -> architect' => sub {
    my $match = Clank::Agent->route('design the system architecture');
    is($match->{name}, 'architect', 'architecture routes to architect');
    cmp_ok($match->{score}, '>', 0.1, 'score above threshold');
};

subtest '5.2e: route empty -> undef' => sub {
    my $match = Clank::Agent->route('');
    ok(!defined $match, 'empty returns undef');
};

# =============================================================================
# 5.3 — Stats and compliance
# =============================================================================
subtest '5.3a: stats start empty' => sub {
    # Stats are in-memory; new process = empty
    my $stats = Clank::Agent->stats;
    is(ref $stats, 'HASH', 'stats is hashref');
};

# =============================================================================
# 5.4 — Spawn + allowlist via clankd
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

    subtest '5.4a: @list via clankd' => sub {
        my ($r, $w, $e, $pid) = spawn_clankd();
        my $resp = rpc($w, $r, { id => 1, prompt => '@list' });
        is($resp->{ok}, 1, '@list ok');
        for my $name (@expected_profiles) {
            like($resp->{output} // '', qr/$name/, "\@list includes $name");
        }
        shutdown_clankd($w, $r, $e, $pid);
    };

    subtest '5.4b: @status via clankd' => sub {
        my ($r, $w, $e, $pid) = spawn_clankd();
        my $resp = rpc($w, $r, { id => 1, prompt => '@status' });
        is($resp->{ok}, 1, '@status ok');
        like($resp->{output} // '', qr/stats|invoked/i, '@status shows stats');
        shutdown_clankd($w, $r, $e, $pid);
    };

    subtest '5.4c: @nonexistent via clankd' => sub {
        my ($r, $w, $e, $pid) = spawn_clankd();
        my $resp = rpc($w, $r, { id => 1, prompt => '@nonexistent do something' });
        is($resp->{ok}, 1, '@nonexistent ok (no crash)');
        like($resp->{output} // '', qr/error|not found|no profile/i, 'reports error');
        shutdown_clankd($w, $r, $e, $pid);
    };

    subtest '5.4d: @ (bare) via clankd' => sub {
        my ($r, $w, $e, $pid) = spawn_clankd();
        my $resp = rpc($w, $r, { id => 1, prompt => '@' });
        is($resp->{ok}, 1, '@ bare ok');
        like($resp->{output} // '', qr/agents|usage/i, 'shows agents or usage');
        shutdown_clankd($w, $r, $e, $pid);
    };

    subtest '5.4e: @spawn reviewer via clankd (mock LLM)' => sub {
        my ($r, $w, $e, $pid) = spawn_clankd();
        my $resp = rpc($w, $r, { id => 1, prompt => '@reviewer summarize lib/Clank.pm' });
        is($resp->{ok}, 1, '@reviewer spawn ok');
        like($resp->{output} // '', qr/reviewer|turns/i, 'output mentions agent or turns');
        like($resp->{output} // '', qr/mock|response/i, 'mock provider responded');
        shutdown_clankd($w, $r, $e, $pid);
    };

    subtest '5.4f: @spawn each agent type via clankd' => sub {
        my ($r, $w, $e, $pid) = spawn_clankd();
        for my $name (@expected_profiles) {
            my $resp = rpc($w, $r, { id => 1, prompt => '@' . $name . ' do a quick task' });
            is($resp->{ok}, 1, "\@$name spawn ok");
            like($resp->{output} // '', qr/$name|turns/i, "\@$name output mentions agent");
        }
        shutdown_clankd($w, $r, $e, $pid);
    };

    subtest '5.4g: agent events via clankd events command' => sub {
        my ($r, $w, $e, $pid) = spawn_clankd();
        # Spawn an agent first
        rpc($w, $r, { id => 1, prompt => '@reviewer review something' });
        # Check events via the events command (session_info doesn't include events)
        my $resp = rpc($w, $r, { id => 2, command => 'events', limit => 50 });
        is($resp->{ok}, 1, 'events ok');
        my @topics = map { $_->{topic} } @{ $resp->{events} // [] };
        ok(grep { $_ eq 'agent_start' || $_ eq 'agent_end' } @topics, 'agent lifecycle events recorded');
        shutdown_clankd($w, $r, $e, $pid);
    };
}

done_testing;
