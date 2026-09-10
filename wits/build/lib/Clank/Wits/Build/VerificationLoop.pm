# CLANK-WIT: name=VerificationLoop
# CLANK-WIT: version=1.0.0
# CLANK-WIT: about=Run comprehensive 6-phase verification loop and produce PASS/FAIL report
# CLANK-WIT: usage=Input: { path?: string } Output: { build: { status, detail }, lint: { status, detail }, tests: { status, passed, failed, total }, security: { status, issues }, diff: { files_changed, review }, overall: string }
# CLANK-WIT: hint=verification, build, lint, test, security scan, diff review, quality gate, comprehensive check
# CLANK-WIT: author=Clank
# CLANK-WIT: license=Artistic-2.0
package Clank::Wits::Build::VerificationLoop;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;
    $api->register_tool(
        name        => 'verification_loop',
        description => 'Run comprehensive 6-phase verification and produce structured PASS/FAIL report',
        parameters  => {
            type       => 'object',
            properties => {
                path => { type => 'string', description => 'Project root directory (default: current dir)' },
            },
            required => [],
        },
        execute => sub {
            my ($args) = @_;
            my $path = $args->{path} // '.';

            my $build  = _phase_build($path);
            my $lint   = _phase_lint($path);
            my $tests  = _phase_tests($path);
            my $sec    = _phase_security($path);
            my $diff   = _phase_diff($path);

            my $overall = 'READY';
            for my $phase ($build, $lint, $tests, $sec) {
                if ($phase->{status} eq 'FAIL') {
                    $overall = 'NOT READY';
                    last;
                }
            }

            return {
                build   => $build,
                lint    => $lint,
                tests   => $tests,
                security => $sec,
                diff    => $diff,
                overall => $overall,
            };
        },
    );
}

sub _phase_build {
    my ($path) = @_;
    my @makefiles = ("$path/Makefile", "$path/makefile", "$path/Build.PL", "$path/Makefile.PL");
    my $has_build = grep { -f $_ } @makefiles;

    unless ($has_build) {
        return { status => 'FAIL', detail => 'No build file found (Makefile, Build.PL, Makefile.PL)' };
    }

    my $cmd;
    if (-f "$path/Makefile.PL") {
        $cmd = "cd $path && perl Makefile.PL && make 2>&1";
    } elsif (-f "$path/Build.PL") {
        $cmd = "cd $path && perl Build.PL && perl Build 2>&1";
    } else {
        $cmd = "cd $path && make 2>&1";
    }

    my $output = `$cmd`;
    my $exit   = $? >> 8;

    return { status => $exit == 0 ? 'PASS' : 'FAIL', detail => $output };
}

sub _phase_lint {
    my ($path) = @_;
    my $has_critic = system("perlcritic --version >/dev/null 2>&1") == 0;
    my $output;

    if ($has_critic) {
        $output = `perlcritic --severity 1 --verbose '%f:%l:%c: %m (%p)\\n' $path/lib 2>&1`;
    } else {
        my @pm_files;
        if (opendir(my $dh, "$path/lib")) {
            while (my $f = readdir($dh)) {
                next unless $f =~ /\.pm$/;
                push @pm_files, "$path/lib/$f" if -f "$path/lib/$f";
            }
            closedir($dh);
        }
        for my $pm (@pm_files) {
            my $out = `perl -c $pm 2>&1`;
            $output .= "$pm: $out";
        }
        $output //= 'No .pm files found in lib/';
    }

    my $exit = $? >> 8;
    return { status => $exit == 0 ? 'PASS' : 'FAIL', detail => $output };
}

sub _phase_tests {
    my ($path) = @_;
    my $has_tests = -d "$path/t";

    unless ($has_tests) {
        return { status => 'FAIL', detail => 'No t/ directory found', passed => 0, failed => 0, total => 0 };
    }

    my $output = `cd $path && prove -l t/ 2>&1`;
    my $exit   = $? >> 8;

    my ($passed, $failed, $total) = (0, 0, 0);
    if ($output =~ /(\d+) tests? ok/) {
        $passed = $1;
    }
    if ($output =~ /(\d+) tests? failed/) {
        $failed = $1;
    }
    $total = $passed + $failed;

    return {
        status => $exit == 0 ? 'PASS' : 'FAIL',
        detail => $output,
        passed => $passed,
        failed => $failed,
        total  => $total,
    };
}

sub _phase_security {
    my ($path) = @_;
    my @issues;
    my @patterns = (
        qr/api[_-]?key/i,
        qr/password\s*=/i,
        qr/secret\s*=/i,
        qr/token\s*=/i,
    );

    my @search_dirs = ("$path/lib", "$path/conf", "$path/config");
    for my $dir (@search_dirs) {
        next unless -d $dir;
        if (opendir(my $dh, $dir)) {
            while (my $f = readdir($dh)) {
                next unless -f "$dir/$f";
                next unless $f =~ /\.(pm|pl|conf|cfg|json|yaml|yml|toml)$/;
                open my $fh, '<', "$dir/$f" or next;
                my $ln = 0;
                while (<$fh>) {
                    $ln++;
                    for my $pat (@patterns) {
                        if ($_ =~ $pat) {
                            push @issues, { file => "$dir/$f", line => $ln, match => $& };
                        }
                    }
                }
                close $fh;
            }
            closedir($dh);
        }
    }

    my $status = @issues ? 'FAIL' : 'PASS';
    return { status => $status, issues => \@issues };
}

sub _phase_diff {
    my ($path) = @_;
    my $output = `cd $path && git diff --stat 2>&1`;
    my @lines  = grep { /\S/ } split /\n/, $output;
    return { files_changed => scalar @lines, review => $output };
}

1;
