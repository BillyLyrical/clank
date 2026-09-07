# CLAM-WIT: name=Architecture
# CLAM-WIT: version=1.0.0
# CLAM-WIT: about=Critique code architecture — structure, coupling, separation of concerns
# CLAM-WIT: usage=Input: { text: "sub process { ... open ... print ... if ... for ... }" } Output: { score: 4, issues: [...], suggestions: [...] }
# CLAM-WIT: hint=critic_architecture, architecture, coupling, separation of concerns
# CLAM-WIT: author=CLAM
# CLAM-WIT: license=Artistic-2.0
package AI::Clam::Wits::Critic::Architecture;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'critic_architecture',
        description => 'Critique code architecture — structure, coupling, separation of concerns',
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

            my @sub_matches = $text =~ /\bsub\s+\w+.*?\n(?:.*?\n)*?\}/gs;
            for my $sub (@sub_matches) {
                my $lines = () = $sub =~ /\n/g;
                if ($lines > 30) {
                    push @issues, { severity => 'medium', message => 'function too long (>30 lines)' };
                    $score -= 2;
                }
            }

            my $sub_count = () = $text =~ /\bsub\s+\w+/g;
            if ($sub_count > 15) {
                push @issues, { severity => 'medium', message => "too many subroutines ($sub_count) — consider modules" };
                $score -= 2;
            }

            if ($text =~ /\b(?:open|close|print|read)\b/ && $text =~ /\b(?:if|while|for)\b/) {
                push @issues, { severity => 'low', message => 'mixing I/O and logic' };
                $score -= 1;
            }

            if ($text =~ /\bsub\s+\w+.*?dispatch\b/s || $text =~ /\bsub\s+\w+.*?route\b/s) {
                push @issues, { severity => 'medium', message => 'dispatcher/router in single module' };
                $score -= 1;
            }

            push @suggestions, 'separate concerns into modules' if $sub_count > 5;
            push @suggestions, 'extract helper functions for complex logic';
            push @suggestions, 'consider dependency injection for testability';

            $score = 0 if $score < 0;
            my $grade = $score >= 8 ? 'A' : $score >= 6 ? 'B' : $score >= 4 ? 'C' : 'D';

            return { topic => 'critic.architecture', score => $score, grade => $grade, issues => \@issues, suggestions => \@suggestions };
        },
    );
}

1;
