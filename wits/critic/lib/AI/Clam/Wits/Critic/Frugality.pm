# CLAM-WIT: name=Frugality
# CLAM-WIT: version=1.0.0
# CLAM-WIT: about=Critique code frugality — resource usage, efficiency, waste reduction
# CLAM-WIT: usage=Input: { text: "my @data = map { process($_) } @huge_list; my @sorted = sort @data;" } Output: { score: 5, issues: [...], suggestions: [...] }
# CLAM-WIT: hint=critic_frugality, frugality, resource usage, waste, efficiency
# CLAM-WIT: author=CLAM
# CLAM-WIT: license=Artistic-2.0
package AI::Clam::Wits::Critic::Frugality;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'critic_frugality',
        description => 'Critique code frugality — resource usage, efficiency, waste reduction',
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

            if ($text =~ /\bmy\s+@\w+\s*=\s*\(/ && $text !~ /\b(?:map|grep)\b/) {
                push @issues, { severity => 'low', message => 'large array literal — consider lazy loading' };
                $score -= 0.5;
            }
            if ($text =~ /\bmy\s+\$[\w]+\s*=\s*(?:\[|\{)/ && $text =~ /\b(?:foreach|for)\b/) {
                push @issues, { severity => 'low', message => 'data structure created in loop — move outside' };
                $score -= 1;
            }
            if ($text =~ /\b(?:sort|grep|map)\b.*\b(?:sort|grep|map)\b/) {
                push @issues, { severity => 'medium', message => 'chained sort/grep/map — combine into single pass' };
                $score -= 1;
            }
            if ($text =~ /\bfor\b.*\bfor\b/s) {
                push @issues, { severity => 'medium', message => 'nested loops — consider algorithm optimization' };
                $score -= 1;
            }
            if ($text =~ /\bsleep\b/) {
                push @issues, { severity => 'low', message => 'sleep in code — consider async/event-driven' };
                $score -= 0.5;
            }
            if ($text =~ /\bmy\s+\$\w+\s*=.*\n.*\$\w+\s*=/s) {
                push @suggestions, 'check if variable is reassigned unnecessarily';
            }
            if ($text =~ /\bopen\b.*\bopen\b/s) {
                push @suggestions, 'reuse file handles instead of reopening';
            }

            push @suggestions, 'use lazy evaluation for large datasets';
            push @suggestions, 'cache expensive computations';
            push @suggestions, 'profile before optimizing';

            $score = 0 if $score < 0;
            my $grade = $score >= 8 ? 'A' : $score >= 6 ? 'B' : $score >= 4 ? 'C' : 'D';

            return { topic => 'critic.frugality', score => $score, grade => $grade, issues => \@issues, suggestions => \@suggestions };
        },
    );
}

1;
