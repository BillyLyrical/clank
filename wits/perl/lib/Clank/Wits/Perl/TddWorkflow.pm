# CLANK-WIT: name=TddWorkflow
# CLANK-WIT: version=1.0.0
# CLANK-WIT: about=Orchestrate TDD cycles: RED (tests fail) → GREEN (tests pass) → REFACTOR (syntax clean)
# CLANK-WIT: usage=Input: { test_file: "t/01_basic.t", module_file: "lib/Foo.pm", description: "Add multiply function" } Output: { red: { passed, failed, output }, green: { passed, failed, output }, refactor: { clean: boolean }, evidence: string }
# CLANK-WIT: hint=tdd, test driven development, red green refactor, prove, test first, coverage, tdd cycle
# CLANK-WIT: author=Clank
# CLANK-WIT: license=Artistic-2.0
package Clank::Wits::Perl::TddWorkflow;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'tdd_cycle',
        description => 'Orchestrate one TDD cycle: run tests expecting failure (RED), verify all pass (GREEN), check syntax after refactor (REFACTOR)',
        parameters  => {
            type       => 'object',
            properties => {
                test_file   => { type => 'string', description => 'Test file to run (e.g. t/01_test.t)' },
                module_file => { type => 'string', description => 'Module file being developed (e.g. lib/Foo.pm)' },
                description => { type => 'string', description => 'Description of what is being implemented' },
            },
            required => ['test_file', 'module_file', 'description'],
        },
        execute => sub {
            my ($args) = @_;
            my $test_file   = $args->{test_file}   // '';
            my $module_file = $args->{module_file} // '';
            my $description = $args->{description} // '';

            return { error => "test_file required" }   unless $test_file;
            return { error => "module_file required" } unless $module_file;
            return { error => "description required" } unless $description;

            my $red   = _run_phase('RED',   $test_file);
            my $green = _run_phase('GREEN', $test_file);
            my $refactor = _run_refactor($module_file);

            my $evidence = _build_evidence($description, $red, $green, $refactor);

            return {
                red      => $red,
                green    => $green,
                refactor => $refactor,
                evidence => $evidence,
            };
        },
    );
}

sub _run_phase {
    my ($phase, $test_file) = @_;

    my $output = `prove -lv $test_file 2>&1`;
    my $exit = $? >> 8;

    my ($passed, $failed, $total) = (0, 0, 0);
    my @errors;

    for my $line (split /\n/, $output) {
        if ($line =~ /^(\d+)\.\.(\d+)/) {
            $total = $2;
        }
        elsif ($line =~ /^ok\s+(\d+)/) {
            $passed++;
        }
        elsif ($line =~ /^not ok\s+(\d+)/) {
            $failed++;
            push @errors, "Test $1 failed";
        }
        elsif ($line =~ /Failed (\d+)/) {
            $failed = $1;
        }
    }

    my $expect_fail = ($phase eq 'RED');
    my $ok;
    if ($expect_fail) {
        $ok = ($failed > 0 || $exit != 0) ? 1 : 0;
    } else {
        $ok = ($failed == 0 && $exit == 0) ? 1 : 0;
    }

    return {
        phase  => $phase,
        passed => $passed,
        failed => $failed,
        total  => $total,
        ok     => $ok,
        exit   => $exit,
        errors => \@errors,
        output => $output,
    };
}

sub _run_refactor {
    my ($module_file) = @_;

    my $output = `$^X -c $module_file 2>&1`;
    my $exit = $? >> 8;
    my $clean = ($exit == 0) ? 1 : 0;

    return {
        clean  => $clean,
        exit   => $exit,
        output => $output,
    };
}

sub _build_evidence {
    my ($description, $red, $green, $refactor) = @_;

    my @lines;
    push @lines, "TDD Cycle Evidence";
    push @lines, "===================";
    push @lines, "Description: $description";
    push @lines, "";
    push @lines, "RED (tests fail before implementation):";
    push @lines, "  Passed: $red->{passed}  Failed: $red->{failed}  Total: $red->{total}";
    push @lines, "  Expected failures: " . ($red->{ok} ? "YES ✓" : "NO ✗ (tests should fail in RED phase)");
    push @lines, "";
    push @lines, "GREEN (tests pass after implementation):";
    push @lines, "  Passed: $green->{passed}  Failed: $green->{failed}  Total: $green->{total}";
    push @lines, "  All passing: " . ($green->{ok} ? "YES ✓" : "NO ✗ (fix failing tests)");
    push @lines, "";
    push @lines, "REFACTOR (syntax check):";
    push @lines, "  Clean: " . ($refactor->{clean} ? "YES ✓" : "NO ✗ (fix syntax errors)");
    push @lines, "";
    push @lines, "Verdict: ";
    if ($red->{ok} && $green->{ok} && $refactor->{ok}) {
        push @lines, "PASS — complete TDD cycle satisfied";
    } else {
        my @failing;
        push @failing, "RED" unless $red->{ok};
        push @failing, "GREEN" unless $green->{ok};
        push @failing, "REFACTOR" unless $refactor->{ok};
        push @lines, "FAIL — issues in: " . join(", ", @failing);
    }

    return join("\n", @lines);
}

1;
