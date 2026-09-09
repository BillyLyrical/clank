# CLANK-WIT: name=Quality
# CLANK-WIT: version=1.0.0
# CLANK-WIT: about=Critique code quality — error handling, best practices, maintainability
# CLANK-WIT: usage=Input: { text: "sub foo { open my $fh, '<', $file; ... }" } Output: { score: 6, issues: [...], suggestions: [...] }
# CLANK-WIT: hint=critic_quality, quality, error handling, best practices
# CLANK-WIT: author=Clank
# CLANK-WIT: license=Artistic-2.0
package Clank::Wits::Critic::Quality;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'critic_quality',
        description => 'Critique code quality — error handling, best practices, maintainability',
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

            if ($text =~ /\bopen\b/ && $text !~ /\bor die|or warn|or return/) {
                push @issues, { severity => 'warning', message => 'open without error handling' };
                $score -= 1;
            }
            if ($text =~ /\beval\s*\{/ && $text !~ /\b\$@/) {
                push @issues, { severity => 'info', message => 'eval without checking $@' };
                $score -= 0.5;
            }
            if ($text =~ /\bmy\s+\$[\w]+\s*=\s*\d+/) {
                push @issues, { severity => 'info', message => 'magic number — consider named constant' };
                $score -= 0.5;
            }
            if ($text =~ /\bexit\b/ && $text !~ /^#!/) {
                push @issues, { severity => 'info', message => 'exit in library code' };
                $score -= 0.5;
            }
            if ($text =~ /^use strict;/m) { push @strengths, 'uses strict' }
            if ($text =~ /^use warnings;/m) { push @strengths, 'uses warnings' }
            if ($text =~ /sub\s+\w+\s*\{[^}]*\breturn\b/) { push @strengths, 'explicit returns' }
            if ($text =~ /\beval\b/) { push @strengths, 'error handling present' }

            $score = 0 if $score < 0;
            my $grade = $score >= 8 ? 'A' : $score >= 6 ? 'B' : $score >= 4 ? 'C' : 'D';

            return { topic => 'critic.quality', score => $score, grade => $grade, issues => \@issues, suggestions => \@suggestions, strengths => \@strengths };
        },
    );
}

1;
