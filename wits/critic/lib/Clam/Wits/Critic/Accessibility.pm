# CLAM-WIT: name=Accessibility
# CLAM-WIT: version=1.0.0
# CLAM-WIT: about=Critique code accessibility — screen readers, keyboard nav, color contrast
# CLAM-WIT: usage=Input: { text: "<button onclick='submit()'>Click here</button>", type: "html" } Output: { score: 4, issues: [...], suggestions: [...] }
# CLAM-WIT: hint=critic_accessibility, accessibility, WCAG, screen reader, keyboard
# CLAM-WIT: author=CLAM
# CLAM-WIT: license=Artistic-2.0
package Clam::Wits::Critic::Accessibility;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'critic_accessibility',
        description => 'Critique code accessibility — screen readers, keyboard nav, color contrast',
        parameters  => {
            type       => 'object',
            properties => {
                text => { type => 'string', description => 'Code text to critique' },
                type => { type => 'string', description => 'Content type', default => 'auto' },
            },
            required => ['text'],
        },
        execute => sub {
            my ($args) = @_;
            my $text = $args->{text} // '';
            my $type = $args->{type} // 'auto';
            return { error => "No text provided" } unless $text;

            my @issues;
            my @suggestions;
            my $score = 10;

            if ($text =~ /<img\b(?![^>]*\balt\b)/i) {
                push @issues, { severity => 'high', message => 'image missing alt attribute' };
                $score -= 2;
            }
            if ($text =~ /<input\b(?![^>]*\b(?:id|aria-label|aria-labelledby)\b)/i) {
                push @issues, { severity => 'medium', message => 'input missing label' };
                $score -= 1;
            }
            if ($text =~ /<a\b(?![^>]*\b(?:aria-label|title)\b)[^>]*>[^<]*</i && $text =~ /\bclick here\b|\bhere\b|\bmore\b/i) {
                push @issues, { severity => 'medium', message => 'link text is not descriptive' };
                $score -= 1;
            }
            if ($text =~ /<div\b[^>]*onclick/i && $text !~ /\b(?:role|tabindex|onkeydown|onkeypress)\b/i) {
                push @issues, { severity => 'high', message => 'interactive div without keyboard support' };
                $score -= 2;
            }
            if ($text =~ /style\s*=\s*["'][^"']*color\s*:/i && $text !~ /\b(?:contrast|aria)\b/i) {
                push @suggestions, 'verify color contrast meets WCAG guidelines';
            }

            push @suggestions, 'add ARIA labels for interactive elements';
            push @suggestions, 'ensure all interactive elements are keyboard accessible';
            push @suggestions, 'use semantic HTML elements (button, nav, main)';
            push @suggestions, 'test with screen reader';

            $score = 0 if $score < 0;
            my $grade = $score >= 8 ? 'A' : $score >= 6 ? 'B' : $score >= 4 ? 'C' : 'D';

            return { topic => 'critic.accessibility', score => $score, grade => $grade, issues => \@issues, suggestions => \@suggestions };
        },
    );
}

1;
