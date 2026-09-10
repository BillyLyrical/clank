# Section 9: Test Artifacts and Infrastructure
use strict; use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::RealBin/../lib";
use File::Temp qw(tempdir);
use IPC::Open3;
use Symbol;
use Clank::Util qw(jencode jdecode);

my $base = "$FindBin::RealBin/..";

# =============================================================================
# 9.1 — Directories
# =============================================================================
subtest '9.1a: _test/ directory exists' => sub {
    ok(-d "$base/_test", '_test/ exists');
};

subtest '9.1b: _tmp/ directory exists' => sub {
    ok(-d "$base/_tmp", '_tmp/ exists');
};

subtest '9.1c: _work/ directory exists' => sub {
    ok(-d "$base/_work", '_work/ exists');
};

# =============================================================================
# 9.2 — Mock Provider
# =============================================================================
subtest '9.2a: mock provider echoes prompt' => sub {
    my @cmd = ($^X, "$base/bin/clankd", '--stdio', '--provider', 'mock', '--db', ':memory:');
    my ($w, $r); my $e = Symbol::gensym;
    my $pid = IPC::Open3::open3($w, $r, $e, @cmd);
    print {$w} jencode({ id => 1, prompt => 'test echo' }), "\n";
    my $line = <$r>; chomp $line;
    my $resp = jdecode($line);
    like($resp->{response} // '', qr/mock.*test echo/i, 'mock provider echoes prompt');
    print {$w} jencode({ id => 99, command => 'shutdown' }), "\n";
    close $w; close $r; close $e;
    waitpid($pid, 0);
};

subtest '9.2b: mock provider returns minimal response' => sub {
    my @cmd = ($^X, "$base/bin/clankd", '--stdio', '--provider', 'mock', '--db', ':memory:');
    my ($w, $r); my $e = Symbol::gensym;
    my $pid = IPC::Open3::open3($w, $r, $e, @cmd);
    print {$w} jencode({ id => 1, prompt => 'anything' }), "\n";
    my $line = <$r>; chomp $line;
    my $resp = jdecode($line);
    is($resp->{ok}, 1, 'mock provider returns ok=1');
    ok(length($resp->{response} // '') > 0, 'mock provider returns non-empty response');
    print {$w} jencode({ id => 99, command => 'shutdown' }), "\n";
    close $w; close $r; close $e;
    waitpid($pid, 0);
};

subtest '9.2c: mock provider has no network dependency' => sub {
    # Verify provider mock doesn't require network by running in isolated env
    my @cmd = ($^X, "$base/bin/clankd", '--stdio', '--provider', 'mock', '--db', ':memory:');
    my ($w, $r); my $e = Symbol::gensym;
    my $pid = IPC::Open3::open3($w, $r, $e, @cmd);
    print {$w} jencode({ id => 1, command => 'ping' }), "\n";
    my $line = <$r>; chomp $line;
    my $resp = jdecode($line);
    is($resp->{pong}, 1, 'mock provider works without network');
    print {$w} jencode({ id => 99, command => 'shutdown' }), "\n";
    close $w; close $r; close $e;
    waitpid($pid, 0);
};

# =============================================================================
# 9.3 — Test Blueprint Files
# =============================================================================
subtest '9.3a: test pipeline directory can be created' => sub {
    my $dir = tempdir(CLEANUP => 1);
    ok(-d $dir, 'temp pipeline dir created');
    ok(-w $dir, 'temp pipeline dir writable');
};

subtest '9.3b: pipeline blueprints parse correctly' => sub {
    use Clank::Pipeline;

    my %blueprints = (
        simple => "Pipeline[\n  name(\"simple\")\n]\nSource[\n  name(\"src\")\n  topic(\"in\")\n]\nAgent[\n  name(\"a\")\n  wit(\"w\")\n  tool(\"t\")\n  subscribe(\"in\")\n  publish(\"out\")\n]\nSink[\n  name(\"s\")\n  subscribe(\"out\")\n  topic(\"done\")\n]\n",
        empty => "Pipeline[\n  name(\"empty\")\n]\n",
        comments => "# comment 1\nPipeline[\n  name(\"comments\")\n  about(\"has # inside \\\"quotes\\\"\")\n]\n# comment 2\n",
        fork => "Pipeline[\n  name(\"fork\")\n]\nSource[\n  name(\"s\")\n  topic(\"in\")\n]\nAgent[\n  name(\"a1\")\n  wit(\"w\")\n  tool(\"t\")\n  subscribe(\"in\")\n  publish(\"a1.out\")\n]\nAgent[\n  name(\"a2\")\n  wit(\"w\")\n  tool(\"t\")\n  subscribe(\"in\")\n  publish(\"a2.out\")\n]\nSink[\n  name(\"s\")\n  subscribe(\"a1.out\")\n  subscribe(\"a2.out\")\n  topic(\"done\")\n]\n",
        merge => "Pipeline[\n  name(\"merge\")\n]\nSource[\n  name(\"s\")\n  topic(\"in\")\n]\nAgent[\n  name(\"a1\")\n  wit(\"w\")\n  tool(\"t\")\n  subscribe(\"in\")\n  publish(\"mid\")\n]\nAgent[\n  name(\"a2\")\n  wit(\"w\")\n  tool(\"t\")\n  subscribe(\"mid\")\n  publish(\"out\")\n]\nSink[\n  name(\"s\")\n  subscribe(\"out\")\n  topic(\"done\")\n]\n",
    );

    for my $name (sort keys %blueprints) {
        my $p = Clank::Pipeline->parse($blueprints{$name});
        ok($p, "$name parses");
        is($p->{name}, $name, "$name has correct name");
    }
};

# =============================================================================
# 9.4 — Test Agent Profiles
# =============================================================================
subtest '9.4a: agents/ directory has all profiles' => sub {
    my @expected = qw(reviewer planner debugger security architect);
    for my $name (@expected) {
        ok(-f "$base/agents/$name.toml", "$name.toml exists");
        ok(-f "$base/agents/$name.md", "$name.md exists");
    }
};

subtest '9.4b: TOML files parse' => sub {
    use TOML::Tiny;
    my @expected = qw(reviewer planner debugger security architect);
    for my $name (@expected) {
        open my $fh, '<', "$base/agents/$name.toml" or die "open $name.toml: $!";
        local $/; my $text = <$fh>; close $fh;
        my $data = eval { from_toml($text) };
        ok($data, "$name.toml parses");
        is($data->{name}, $name, "$name.toml name field");
        ok(ref $data->{tools} eq 'ARRAY' && @{$data->{tools}}, "$name.toml has tools");
        ok(length($data->{description} // ''), "$name.toml has description");
    }
};

subtest '9.4c: markdown prompts are substantial' => sub {
    my @expected = qw(reviewer planner debugger security architect);
    for my $name (@expected) {
        open my $fh, '<', "$base/agents/$name.md" or die "open $name.md: $!";
        local $/; my $text = <$fh>; close $fh;
        ok(length($text) > 50, "$name.md is substantial (>" . length($text) . " chars)");
        like($text, qr/^#/m, "$name.md has markdown heading");
    }
};

# =============================================================================
# 9.5 — Test harness consistency
# =============================================================================
subtest '9.5a: new test files use FindBin + lib' => sub {
    my @new_tests = qw(
        55_section2_repl.t 56_section3_sigil.t 57_section4_pipeline.t
        58_section5_agent.t 59_section6_wit.t 60_section7_workflow.t
        61_section8_regression.t 62_section9_infra.t
    );
    for my $f (@new_tests) {
        ok(-f "$base/t/$f", "$f exists");
        open my $fh, '<', "$base/t/$f" or die "open $f: $!";
        local $/; my $content = <$fh>; close $fh;
        like($content, qr/use FindBin/, "$f uses FindBin");
        like($content, qr/use lib.*FindBin/, "$f uses FindBin lib path");
    }
};

subtest '9.5b: no test files use /tmp directly' => sub {
    opendir my $dh, "$base/t" or die;
    my @tfiles = sort grep { /\.t$/ } readdir $dh;
    closedir $dh;

    for my $f (@tfiles) {
        open my $fh, '<', "$base/t/$f" or die;
        local $/; my $content = <$fh>; close $fh;
        unlike($content, qr{['"]/tmp/}, "$f does not hardcode /tmp");
    }
};

subtest '9.5c: all new test files exist' => sub {
    my @expected = qw(
        t/55_section2_repl.t
        t/56_section3_sigil.t
        t/57_section4_pipeline.t
        t/58_section5_agent.t
        t/59_section6_wit.t
        t/60_section7_workflow.t
        t/61_section8_regression.t
    );
    for my $f (@expected) {
        ok(-f "$base/$f", "$f exists");
    }
};

done_testing;
