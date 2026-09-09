# CLANK-WIT: name=Style
# CLANK-WIT: version=1.0.0
# CLANK-WIT: about=Critique code style — formatting, conventions, idioms
# CLANK-WIT: usage=Input: { text: "sub foo{\nmy $x=1;\nreturn $x;\n}" } Output: { score: 4, issues: [...], suggestions: [...] }
# CLANK-WIT: hint=critic_style, code style, formatting, conventions
# CLANK-WIT: author=Clank
# CLANK-WIT: license=Artistic-2.0
package Clank::Wits::Critic::Style;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'critic_style',
        description => 'Critique code style — formatting, conventions, idioms',
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

            if ($text =~ /\t/ && $text =~ /  /) {
                push @issues, { severity => 'low', message => 'mixed tabs and spaces' };
                $score -= 0.5;
            }
            if ($text =~ /\s+$/) {
                push @issues, { severity => 'low', message => 'trailing whitespace' };
                $score -= 0.5;
            }
            if ($text =~ /\b(?:sub|if|while|for)\b[^(]*\n/) {
                push @issues, { severity => 'low', message => 'missing space before brace' };
                $score -= 0.5;
            }
            if ($text =~ /\bmy\s+\$/ && $text !~ /\buse strict\b/) {
                push @issues, { severity => 'medium', message => 'variable declarations without strict' };
                $score -= 1;
            }
            if ($text =~ /\breturn\b\s*\(/) {
                push @suggestions, 'unnecessary parentheses after return';
            }
            if ($text =~ /\bif\s*\(\s*\$/) {
                push @suggestions, 'consider postfix if for simple conditions';
            }

            push @suggestions, 'follow consistent naming conventions';
            push @suggestions, 'use perltidy for consistent formatting';

            $score = 0 if $score < 0;
            my $grade = $score >= 8 ? 'A' : $score >= 6 ? 'B' : $score >= 4 ? 'C' : 'D';

            return { topic => 'critic.style', score => $score, grade => $grade, issues => \@issues, suggestions => \@suggestions };
        },
    );
}

1;
