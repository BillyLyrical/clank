# CLAM-WIT: name=Ethics
# CLAM-WIT: version=1.0.0
# CLAM-WIT: about=Critique code ethics — fairness, bias, privacy, consent
# CLAM-WIT: usage=Input: { text: "sub filter_users { return grep { $_->{age} > 18 } @users; }" } Output: { score: 6, issues: [...], suggestions: [...] }
# CLAM-WIT: hint=critic_ethics, ethics, bias, privacy, consent, dark patterns
# CLAM-WIT: author=CLAM
# CLAM-WIT: license=Artistic-2.0
package Clam::Wits::Critic::Ethics;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'critic_ethics',
        description => 'Critique code ethics — fairness, bias, privacy, consent',
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

            if ($text =~ /\b(?:race|ethnic|gender|sex|age|religion|disability)\b.*[<>=!]+/i) {
                push @issues, { severity => 'high', message => 'potential discriminatory filter' };
                $score -= 3;
            }
            if ($text =~ /\b(?:male|female|man|woman|boy|girl)\b.*(?:==|eq)/i) {
                push @issues, { severity => 'medium', message => 'gender-based filtering' };
                $score -= 2;
            }
            if ($text =~ /\b(?:log|print|send|store)\b.*\b(?:password|ssn|credit|email|phone)\b/i) {
                push @issues, { severity => 'high', message => 'logging/storing sensitive data' };
                $score -= 3;
            }
            if ($text =~ /\b(?:track|monitor|log)\b.*\b(?:user|visitor|client)\b/i && $text !~ /\bconsent\b/i) {
                push @issues, { severity => 'medium', message => 'tracking without explicit consent' };
                $score -= 2;
            }
            if ($text =~ /\b(?:confirm|subscribe|accept)\b.*\b(?:hard|difficult|impossible)\b/i) {
                push @issues, { severity => 'medium', message => 'potential dark pattern' };
                $score -= 2;
            }
            if ($text =~ /\b(?:hide|conceal|obfuscate)\b.*\b(?:cancel|unsubscribe|opt.out)\b/i) {
                push @issues, { severity => 'high', message => 'hiding opt-out mechanism' };
                $score -= 3;
            }
            if ($text =~ /\b(?:collect|store|share|process)\b.*\b(?:data|info|personal)\b/i && $text !~ /\bconsent\b/i) {
                push @suggestions, 'add explicit consent mechanism for data collection';
            }
            push @suggestions, 'implement data minimization (collect only what is needed)';
            push @suggestions, 'provide clear privacy policy';
            push @suggestions, 'allow users to export/delete their data';

            $score = 0 if $score < 0;
            my $grade = $score >= 8 ? 'A' : $score >= 6 ? 'B' : $score >= 4 ? 'C' : 'D';

            return { topic => 'critic.ethics', score => $score, grade => $grade, issues => \@issues, suggestions => \@suggestions };
        },
    );
}

1;
