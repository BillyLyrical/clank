# CLAM-WIT: name=Bisect
# CLAM-WIT: version=1.0.0
# CLAM-WIT: about=Automated binary search for bug introduction — find which commit broke it
# CLAM-WIT: usage=Input: { path: ".", good: "abc123", bad: "HEAD", test: "prove -l t/test.t" } Output: { found: true, culprit: "def456", message: "...", steps: 5 }
# CLAM-WIT: hint=git bisect, binary search, find bad commit, regression
# CLAM-WIT: author=CLAM
# CLAM-WIT: license=Artistic-2.0
package Clam::Wits::Git::Bisect;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'git_bisect',
        description => 'Automated binary search for bug introduction',
        parameters  => {
            type       => 'object',
            properties => {
                path      => { type => 'string', description => 'Repository path', default => '.' },
                good      => { type => 'string', description => 'Known good commit hash' },
                bad       => { type => 'string', description => 'Known bad commit hash', default => 'HEAD' },
                test      => { type => 'string', description => 'Test command to run' },
                auto_start => { type => 'boolean', description => 'Auto-start bisect', default => 1 },
            },
            required => ['good', 'test'],
        },
        execute => sub {
            my ($args) = @_;
            my $path = $args->{path} // '.';
            my $good = $args->{good} // '';
            my $bad = $args->{bad} // 'HEAD';
            my $test_cmd = $args->{test} // '';
            my $auto_start = $args->{auto_start} // 1;

            return { error => "No good commit specified" } unless $good;
            return { error => "No test command specified" } unless $test_cmd;

            if ($auto_start) {
                my $start = `cd '$path' && git bisect start && git bisect bad $bad && git bisect good $good 2>&1`;
                if ($? >> 8 != 0) {
                    return { error => "Bisect start failed: $start" };
                }
            }

            my $output = `cd '$path' && git bisect run $test_cmd 2>&1`;
            my $exit = $? >> 8;

            my $culprit = '';
            my $message = '';
            my $steps = 0;
            my $found = 0;

            for my $line (split /\n/, $output) {
                $steps++ if $line =~ /bisect/i && $line =~ /step/i;

                if ($line =~ /^([0-9a-f]{7,40})\s+is the first bad commit$/i) {
                    $culprit = $1;
                    $found = 1;
                }

                if ($found && $line =~ /^Author:\s+(.+)$/i) {
                }
                if ($found && $line =~ /^(?:\s{4}|\t)(.+)$/ && !$message) {
                    $message = $1;
                }
            }

            if ($culprit) {
                my $details = `cd '$path' && git log -1 --pretty=format:"%H|%h|%an|%ai|%s" $culprit 2>/dev/null`;
                if ($details =~ /^([0-9a-f]{40})\|([0-9a-f]+)\|(.+?)\|(.+?)\|(.+)$/) {
                    $message = $5;
                    $culprit = {
                        hash    => $1,
                        short   => $2,
                        author  => $3,
                        date    => $4,
                        message => $5,
                    };
                }
            }

            `cd '$path' && git bisect reset 2>/dev/null`;

            return {
                found   => $found,
                culprit => $culprit,
                message => $message,
                steps   => $steps,
                good    => $good,
                bad     => $bad,
            };
        },
    );
}

1;
