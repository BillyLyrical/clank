# CLAM-WIT: name=Safety
# CLAM-WIT: version=1.0.0
# CLAM-WIT: about=Critique code safety — error handling, edge cases, resource leaks
# CLAM-WIT: usage=Input: { text: "open my $fh, '<', $file;" } Output: { score: 5, issues: [...], suggestions: [...] }
# CLAM-WIT: hint=critic_safety, safety, error handling, resource leaks
# CLAM-WIT: author=CLAM
# CLAM-WIT: license=Artistic-2.0
package Clam::Wits::Critic::Safety;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'critic_safety',
        description => 'Critique code safety — error handling, edge cases, resource leaks',
        parameters  => {
            type       => 'object',
            properties => {
                text => { type => 'string', description => 'Code text to critique' },
            },
            required => ['text'],
        },
        execute => sub {
            my ($args) = @_;
            my $text = $args->{text} // '';
            return { error => "No text provided" } unless $text;

            my @issues;
            my @suggestions;
            my $score = 10;

            if ($text =~ /\bopen\b/ && $text !~ /\bclose\b/ && $text !~ /\buse\s+autodie\b/) {
                push @issues, { severity => 'high', message => 'file handle never closed — resource leak' };
                $score -= 2;
            }
            if ($text =~ /\bopen\b/ && $text !~ /\bor\b/) {
                push @issues, { severity => 'high', message => 'open without error check' };
                $score -= 2;
            }
            if ($text =~ /\bdivision\b|\b\/\s*0\b|\$\w+\s*\/\s*\$/) {
                push @issues, { severity => 'high', message => 'potential division by zero' };
                $score -= 2;
            }
            if ($text =~ /\buninitialized\b|\buse\s+of\s+uninitialized\b/) {
                push @issues, { severity => 'medium', message => 'uninitialized value usage' };
                $score -= 1;
            }
            if ($text =~ /\barray\b.*\b\$#\w+/ && $text !~ /\bof\b/) {
                push @issues, { severity => 'low', message => 'unchecked array bounds' };
                $score -= 0.5;
            }
            if ($text =~ /\beval\b/ && $text =~ /\b\$@/) { push @suggestions, 'eval with error checking present' }
            if ($text =~ /\buse\s+autodie\b/) { push @suggestions, 'autodie handles open/close errors' }
            push @suggestions, 'add boundary checks for array/index access';
            push @suggestions, 'use eval for risky operations';

            $score = 0 if $score < 0;
            my $grade = $score >= 8 ? 'A' : $score >= 6 ? 'B' : $score >= 4 ? 'C' : 'D';

            return { topic => 'critic.safety', score => $score, grade => $grade, issues => \@issues, suggestions => \@suggestions };
        },
    );
}

1;
