# CLAM-WIT: name=Usability
# CLAM-WIT: version=1.0.0
# CLAM-WIT: about=Critique code usability — API design, error messages, developer experience
# CLAM-WIT: usage=Input: { text: "sub process { my ($data, $format, $encoding, $strict) = @_; ... }" } Output: { score: 5, issues: [...], suggestions: [...] }
# CLAM-WIT: hint=critic_usability, usability, API design, error messages, DX
# CLAM-WIT: author=CLAM
# CLAM-WIT: license=Artistic-2.0
package Clam::Wits::Critic::Usability;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'critic_usability',
        description => 'Critique code usability — API design, error messages, developer experience',
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

            my @sub_sigs = $text =~ /\bsub\s+(\w+)\s*\(([^)]*)\)/g;
            for my $sig (@sub_sigs) {
                my ($name, $params) = @$sig;
                my @params = split(/,/, $params);
                if (@params > 4) {
                    push @issues, { severity => 'medium', message => "$name has too many parameters (" . scalar(@params) . ")" };
                    $score -= 1;
                }
            }

            if ($text =~ /\bdie\s*['"]/ && $text !~ /\b\$/) {
                push @issues, { severity => 'low', message => 'static die message — include context' };
                $score -= 0.5;
            }
            if ($text =~ /\breturn\s+undef\b/) {
                push @issues, { severity => 'low', message => 'return undef — consider error object' };
                $score -= 0.5;
            }
            if ($text =~ /\bsub\s+\w+/ && $text !~ /=head1/) {
                push @issues, { severity => 'medium', message => 'subroutines without documentation' };
                $score -= 1;
            }
            if ($text =~ /\bsub\s+\w+/ && $text !~ /=head2/) {
                push @suggestions, 'add POD documentation for each subroutine';
            }
            if ($text =~ /\b(?:config|option|setting|preference)\b/i && $text !~ /\bdefault\b/i) {
                push @suggestions, 'provide sensible defaults for configuration';
            }

            push @suggestions, 'use named parameters for clarity';
            push @suggestions, 'return error objects instead of undef';
            push @suggestions, 'add examples in documentation';

            $score = 0 if $score < 0;
            my $grade = $score >= 8 ? 'A' : $score >= 6 ? 'B' : $score >= 4 ? 'C' : 'D';

            return { topic => 'critic.usability', score => $score, grade => $grade, issues => \@issues, suggestions => \@suggestions };
        },
    );
}

1;
