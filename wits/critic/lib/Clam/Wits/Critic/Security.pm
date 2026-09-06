# CLAM-WIT: name=Security
# CLAM-WIT: version=1.0.0
# CLAM-WIT: about=Critique code security — vulnerabilities, secrets, injection risks
# CLAM-WIT: usage=Input: { text: "system(\"rm -rf $dir\")" } Output: { score: 2, issues: [...], suggestions: [...] }
# CLAM-WIT: hint=critic_security, security, vulnerabilities, secrets, injection
# CLAM-WIT: author=CLAM
# CLAM-WIT: license=Artistic-2.0
package Clam::Wits::Critic::Security;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'critic_security',
        description => 'Critique code security — vulnerabilities, secrets, injection risks',
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

            if ($text =~ /\b(?:system|exec|qx|`\$[^`]*`)/) {
                push @issues, { severity => 'high', message => 'shell command execution — injection risk' };
                $score -= 3;
            }
            if ($text =~ /\b(?:eval|do)\s*\$/) {
                push @issues, { severity => 'high', message => 'eval of variable — code injection' };
                $score -= 3;
            }
            if ($text =~ /(?:password|secret|key|token)\s*=\s*['"]/i) {
                push @issues, { severity => 'high', message => 'hardcoded secret' };
                $score -= 3;
            }
            if ($text =~ /\b(?:SELECT|INSERT|UPDATE|DELETE)\b.*\$/) {
                push @issues, { severity => 'high', message => 'SQL with interpolated variables — SQL injection' };
                $score -= 3;
            }
            if ($text =~ /\bopen\b.*\$(?!\w+\s*(?:\||>))/ && $text !~ /\bopen\b.*['"]/) {
                push @issues, { severity => 'medium', message => 'open with variable path — path traversal' };
                $score -= 1;
            }

            push @suggestions, 'validate all user input' unless $text =~ /\b(?:validate|sanitiz|escape)\b/;
            push @suggestions, 'use parameterized queries' if $text =~ /\b(?:execute|query)\b.*\$/;
            push @suggestions, 'use taint mode for untrusted input' unless $text =~ /\buse\s+strict.*taint\b/;

            $score = 0 if $score < 0;
            my $grade = $score >= 8 ? 'A' : $score >= 6 ? 'B' : $score >= 4 ? 'C' : 'D';

            return { topic => 'critic.security', score => $score, grade => $grade, issues => \@issues, suggestions => \@suggestions };
        },
    );
}

1;
