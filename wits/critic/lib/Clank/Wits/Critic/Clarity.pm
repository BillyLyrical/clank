# CLANK-WIT: name=Clarity
# CLANK-WIT: version=1.0.0
# CLANK-WIT: about=Critique code clarity — readability, naming, documentation
# CLANK-WIT: usage=Input: { text: "sub f { my $x = shift; return $x * 2; }" } Output: { score: 5, issues: [...], suggestions: [...] }
# CLANK-WIT: hint=critic_clarity, clarity, readability, naming, documentation
# CLANK-WIT: author=Clank
# CLANK-WIT: license=Artistic-2.0
package Clank::Wits::Critic::Clarity;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'critic_clarity',
        description => 'Critique code clarity — readability, naming, documentation',
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
            my @strengths;
            my $score = 10;

            if ($text =~ /\bmy\s+\$[a-z]\b/) {
                push @issues, { severity => 'low', message => 'single-letter variable name' };
                $score -= 0.5;
            }
            if ($text =~ /\b(?:if|while)\b[^{]*\{/ && $text =~ /\n.*\n.*\n.*\b(?:if|while)\b/s) {
                push @issues, { severity => 'medium', message => 'deeply nested conditionals' };
                $score -= 1;
            }
            if ($text =~ /# TODO|# FIXME|# HACK|# XXX/) {
                push @issues, { severity => 'low', message => 'contains TODO/FIXME markers' };
                $score -= 0.5;
            }
            if ($text =~ /\bsub\s+[a-z]\b/) {
                push @issues, { severity => 'low', message => 'single-letter subroutine name' };
                $score -= 1;
            }
            if ($text =~ /^=head1/m) { push @strengths, 'has documentation' }
            if ($text =~ /#.*/ && length($&) > 10) { push @strengths, 'has comments' }

            push @suggestions, 'use descriptive variable names' if $text =~ /\bmy\s+\$[a-z]\b/;
            push @suggestions, 'add comments for complex logic' if $text =~ /\b(?:if|while)\b.*(?:&&|\|\|)/;
            push @suggestions, 'break long functions into smaller ones';

            $score = 0 if $score < 0;
            my $grade = $score >= 8 ? 'A' : $score >= 6 ? 'B' : $score >= 4 ? 'C' : 'D';

            return { topic => 'critic.clarity', score => $score, grade => $grade, issues => \@issues, suggestions => \@suggestions, strengths => \@strengths };
        },
    );
}

1;
