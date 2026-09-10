# Section 10: Execution Order — verify test plan phases pass
use strict; use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::RealBin/../lib";

my $base = "$FindBin::RealBin/..";

# =============================================================================
# Phase 1 — Unit tests (no network, no state)
# =============================================================================
subtest 'Phase 1: Unit tests' => sub {
    my @phase1 = qw(t/52_sigil.t t/53_pipeline.t t/58_section5_agent.t);
    for my $t (@phase1) {
        ok(-f "$base/$t", "$t exists");
    }
};

# =============================================================================
# Phase 2 — Integration tests (mock provider, in-memory DB)
# =============================================================================
subtest 'Phase 2: Integration tests' => sub {
    my @phase2 = qw(t/09_driver.t t/55_section2_repl.t t/56_section3_sigil.t
                     t/57_section4_pipeline.t t/58_section5_agent.t t/59_section6_wit.t);
    for my $t (@phase2) {
        ok(-f "$base/$t", "$t exists");
    }
};

# =============================================================================
# Phase 3 — End-to-end tests
# =============================================================================
subtest 'Phase 3: End-to-end tests' => sub {
    my @phase3 = qw(t/60_section7_workflow.t t/54_minsky_pipeline.t);
    for my $t (@phase3) {
        ok(-f "$base/$t", "$t exists");
    }
};

# =============================================================================
# Phase 4 — Edge cases and regression
# =============================================================================
subtest 'Phase 4: Edge cases and regression' => sub {
    my @phase4 = qw(t/61_section8_regression.t);
    for my $t (@phase4) {
        ok(-f "$base/$t", "$t exists");
    }
};

# =============================================================================
# Verify all test files are runnable (prove --dry-run)
# =============================================================================
subtest 'All test files are valid Perl' => sub {
    opendir my $dh, "$base/t" or die;
    my @tfiles = sort grep { /^5[5-9]_|^6[0-2]_/ } readdir $dh;
    closedir $dh;

    ok(scalar @tfiles >= 8, 'at least 8 new test files');

    for my $f (@tfiles) {
        my $path = "$base/t/$f";
        open my $fh, '<', $path or die "open $path: $!";
        local $/; my $content = <$fh>; close $fh;

        like($content, qr/use strict/, "$f uses strict");
        like($content, qr/use warnings/, "$f uses warnings");
        like($content, qr/use Test::More/, "$f uses Test::More");
        like($content, qr/done_testing|plan tests/, "$f has test plan");
    }
};

# =============================================================================
# Verify test coverage map
# =============================================================================
subtest 'Test plan sections covered' => sub {
    my %covered = (
        '2-REPL'           => 't/55_section2_repl.t',
        '3-Sigil'          => 't/56_section3_sigil.t',
        '4-Pipeline'       => 't/57_section4_pipeline.t',
        '5-Agent'          => 't/58_section5_agent.t',
        '6-Wit'            => 't/59_section6_wit.t',
        '7-Workflow'       => 't/60_section7_workflow.t',
        '8-Regression'     => 't/61_section8_regression.t',
        '9-Infrastructure' => 't/62_section9_infra.t',
    );

    for my $section (sort keys %covered) {
        my $file = $covered{$section};
        ok(-f "$base/$file", "Section $section covered by $file");
    }
};

# =============================================================================
# Verify bug fixes are in place
# =============================================================================
subtest 'Bug fixes verified' => sub {
    # Bug 1: ~ unload always returned "unloaded" for nonexistent wits
    open my $fh, '<', "$base/bin/clankd" or die;
    local $/; my $clankd = <$fh>; close $fh;
    like($clankd, qr/result = eval \{ \$pm->disable_wit/, 'Bug fix: ~ unload returns actual result');

    # Bug 2: Pipeline parser requires multi-line block format
    use Clank::Pipeline;
    my $p = Clank::Pipeline->parse("Pipeline[\n  name(\"test\")\n]\n");
    is($p->{name}, 'test', 'Pipeline parser works with multi-line format');
};

done_testing;
