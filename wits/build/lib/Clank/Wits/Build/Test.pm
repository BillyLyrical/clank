# CLANK-WIT: name=Test
# CLANK-WIT: version=1.0.0
# CLANK-WIT: about=Run Perl test suite via prove or make test
# CLANK-WIT: usage=Input: { dir: "/path/to/project", verbose: true } Output: { ok: true, output: "...", exit_code: 0, tests_run: 100, tests_failed: 0 }
# CLANK-WIT: hint=perl test, prove, make test, test suite, t/ directory
# CLANK-WIT: author=Clank
# CLANK-WIT: license=Artistic-2.0
package Clank::Wits::Build::Test;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;
    $api->register_tool(
        name        => 'build_test',
        description => 'Run Perl test suite via prove or make test',
        parameters  => {
            type       => 'object',
            properties => {
                dir     => { type => 'string', description => 'Project directory' },
                verbose => { type => 'boolean', description => 'Verbose output (-v)' },
                jobs    => { type => 'integer', description => 'Parallel test jobs (-j)', default => 1 },
                pattern => { type => 'string', description => 'Test file pattern' },
            },
            required => [],
        },
        execute => sub {
            my ($args) = @_;
            my $dir     = $args->{dir}     // '.';
            my $verbose = $args->{verbose} ? '-v' : '';
            my $jobs    = $args->{jobs}    // 1;
            my $pattern = $args->{pattern} // '';

            my $cmd;
            if (-f "$dir/Makefile" && `cd $dir && grep -q '^test:' Makefile 2>/dev/null`) {
                $cmd = "cd $dir && make test 2>&1";
            }
            elsif (-d "$dir/t") {
                $cmd = "cd $dir && prove -lr $verbose -j$jobs";
                $cmd .= " $pattern" if $pattern;
                $cmd .= " t/" if !$pattern;
                $cmd .= " 2>&1";
            }
            else {
                return { error => "No t/ directory or Makefile found in $dir" };
            }

            my $output = `$cmd`;
            my $exit_code = $? >> 8;

            my ($run, $failed) = (0, 0);
            if ($output =~ /(\d+) tests? ran/) {
                $run = $1;
            }
            if ($output =~ /(\d+) (?:tests? )?failed/) {
                $failed = $1;
            }

            return {
                ok          => $exit_code == 0 ? 1 : 0,
                output      => $output,
                exit_code   => $exit_code,
                tests_run   => $run,
                tests_failed => $failed,
                dir         => $dir,
            };
        },
    );
}

1;
