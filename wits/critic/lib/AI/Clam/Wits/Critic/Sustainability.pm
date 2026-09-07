# CLAM-WIT: name=Sustainability
# CLAM-WIT: version=1.0.0
# CLAM-WIT: about=Critique code sustainability — maintainability, long-term viability
# CLAM-WIT: usage=Input: { text: "sub legacy_process { ... } # 500 lines of uncommented code" } Output: { score: 3, issues: [...], suggestions: [...] }
# CLAM-WIT: hint=critic_sustainability, sustainability, maintainability, technical debt
# CLAM-WIT: author=CLAM
# CLAM-WIT: license=Artistic-2.0
package AI::Clam::Wits::Critic::Sustainability;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'critic_sustainability',
        description => 'Critique code sustainability — maintainability, long-term viability',
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

            my $debt_count = () = $text =~ /\b(?:TODO|FIXME|HACK|XXX|DEPRECATED|WORKAROUND)\b/gi;
            if ($debt_count > 0) {
                push @issues, { severity => 'medium', message => "$debt_count technical debt markers" };
                $score -= $debt_count * 0.5;
            }

            if ($text =~ /\b(?:unless|or\s+die|or\s+warn)\b/ && $text !~ /=head1/) {
                push @issues, { severity => 'low', message => 'older Perl idiom — consider modernizing' };
                $score -= 0.5;
            }

            my $sub_count = () = $text =~ /\bsub\s+\w+/g;
            my $line_count = () = $text =~ /\n/g;
            if ($line_count > 200) {
                push @issues, { severity => 'medium', message => "large file ($line_count lines) — consider splitting" };
                $score -= 1;
            }

            if ($text !~ /\b(?:Test::|ok\(|is\(|use_ok)/ && $text =~ /\bsub\s+\w+/) {
                push @suggestions, 'add tests for subroutines';
            }
            if ($text !~ /=head1/ && $text =~ /\bsub\s+\w+/) {
                push @suggestions, 'add POD documentation';
            }

            push @suggestions, 'refactor when touching code';
            push @suggestions, 'track and address technical debt regularly';
            push @suggestions, 'ensure dependencies are maintained';
            push @suggestions, 'plan for deprecation cycles';

            $score = 0 if $score < 0;
            my $grade = $score >= 8 ? 'A' : $score >= 6 ? 'B' : $score >= 4 ? 'C' : 'D';

            return { topic => 'critic.sustainability', score => $score, grade => $grade, issues => \@issues, suggestions => \@suggestions };
        },
    );
}

1;
