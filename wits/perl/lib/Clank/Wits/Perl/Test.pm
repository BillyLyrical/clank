# CLANK-WIT: name=Test
# CLANK-WIT: version=1.0.0
# CLANK-WIT: about=Run Perl tests and parse TAP output
# CLANK-WIT: usage=Input: { file: "t/01_test.t" } or { dir: "t/" } Output: { passed: 10, failed: 2, total: 12, errors: [...] }
# CLANK-WIT: hint=perl_test, run tests, prove, TAP output
# CLANK-WIT: author=Clank
# CLANK-WIT: license=Artistic-2.0
package Clank::Wits::Perl::Test;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'perl_test',
        description => 'Run Perl tests and parse TAP output',
        parameters  => {
            type       => 'object',
            properties => {
                file => { type => 'string', description => 'Test file to run' },
                dir  => { type => 'string', description => 'Test directory to run' },
            },
        },
        execute => sub {
            my ($args) = @_;
            my $file = $args->{file} // '';
            my $dir  = $args->{dir}  // '';

            my $target = $file || $dir || 't/';
            return { error => "No test file or directory specified" } unless $target;

            my $output = `$^X -Ilib prove -v $target 2>&1`;
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

            return {
                passed => $passed,
                failed => $failed,
                total  => $total,
                exit   => $exit,
                errors => \@errors,
                output => $output,
            };
        },
    );
}

1;
