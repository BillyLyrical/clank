# CLANK-WIT: name=Performance
# CLANK-WIT: version=1.0.0
# CLANK-WIT: about=Critique code performance — speed, memory, efficiency
# CLANK-WIT: usage=Input: { text: "for my $item (@list) { for my $other (@list) { ... } }" } Output: { score: 5, issues: [...], suggestions: [...] }
# CLANK-WIT: hint=critic_performance, performance, speed, memory, efficiency
# CLANK-WIT: author=Clank
# CLANK-WIT: license=Artistic-2.0
package Clank::Wits::Critic::Performance;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'critic_performance',
        description => 'Critique code performance — speed, memory, efficiency',
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

            if ($text =~ /\bfor\b.*\b(?:sort|grep|map)\b.*\bfor\b/s) {
                push @issues, { severity => 'medium', message => 'nested sort/grep/map — O(n^2) potential' };
                $score -= 2;
            }
            if ($text =~ /\bfor\b.*\bfor\b/s) {
                push @issues, { severity => 'medium', message => 'nested loops — potential performance issue' };
                $score -= 2;
            }
            if ($text =~ /\b(?:push|unshift)\b.*\bfor\b/s) {
                push @issues, { severity => 'low', message => 'repeated array modification in loop' };
                $score -= 1;
            }
            if ($text =~ /\bopen\b.*\bwhile\b.*\bclose\b/s) {
                push @issues, { severity => 'low', message => 'file opened/closed in loop — move outside' };
                $score -= 1;
            }
            if ($text =~ /\bmy\s+@\w+\s*=\s*sort\b/) {
                push @suggestions, 'consider caching sort results if reused';
            }
            if ($text =~ /\b(?:grep|map)\b.*\b(?:grep|map)\b/) {
                push @suggestions, 'chain grep/map in single pass when possible';
            }

            $score = 0 if $score < 0;
            my $grade = $score >= 8 ? 'A' : $score >= 6 ? 'B' : $score >= 4 ? 'C' : 'D';

            return { topic => 'critic.performance', score => $score, grade => $grade, issues => \@issues, suggestions => \@suggestions };
        },
    );
}

1;
