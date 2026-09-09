# CLANK-WIT: name=Review
# CLANK-WIT: version=1.0.0
# CLANK-WIT: about=Code review Perl code with suggestions
# CLANK-WIT: usage=Input: { code: "sub foo { system('rm -rf /'); }" } Output: { issues: [{ type: "security", severity: "high", msg: "..." }] }
# CLANK-WIT: hint=perl_review, code review, security check, style check
# CLANK-WIT: author=Clank
# CLANK-WIT: license=Artistic-2.0
package Clank::Wits::Perl::Review;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'perl_review',
        description => 'Code review Perl code with suggestions',
        parameters  => {
            type       => 'object',
            properties => {
                code => { type => 'string', description => 'Perl code to review' },
            },
            required => ['code'],
        },
        execute => sub {
            my ($args) = @_;
            my $code = $args->{code} // '';

            return { issues => [] } unless $code;

            my @issues;

            if ($code =~ /\bsystem\s*\(/) {
                push @issues, {
                    type     => 'security',
                    severity => 'high',
                    msg      => 'system() call — use IPC::Run or capture for safety',
                };
            }
            if ($code =~ /\beval\s*\{[^}]*\beval\b/) {
                push @issues, {
                    type     => 'security',
                    severity => 'medium',
                    msg      => 'Nested eval — consider error handling strategy',
                };
            }
            if ($code =~ /\bexec\s*\(/) {
                push @issues, {
                    type     => 'security',
                    severity => 'high',
                    msg      => 'exec() replaces process — ensure intentional',
                };
            }
            if ($code !~ /^use strict;/m) {
                push @issues, {
                    type     => 'style',
                    severity => 'medium',
                    msg      => 'Missing "use strict"',
                };
            }
            if ($code !~ /^use warnings;/m) {
                push @issues, {
                    type     => 'style',
                    severity => 'low',
                    msg      => 'Missing "use warnings"',
                };
            }
            if ($code =~ /\bmy\s+\(\s*\)/) {
                push @issues, {
                    type     => 'style',
                    severity => 'low',
                    msg      => 'Empty my() — remove or add variables',
                };
            }
            if ($code =~ /\$result\s*=\s*\$/) {
                push @issues, {
                    type     => 'style',
                    severity => 'low',
                    msg      => 'Direct assignment — consider clarity',
                };
            }
            if ($code =~ /\$hash\{key\}/ && $code !~ /exists\s+\$hash\{key\}/) {
                push @issues, {
                    type     => 'bug',
                    severity => 'medium',
                    msg      => 'Hash access without exists check — may warn on missing keys',
                };
            }

            return { issues => \@issues };
        },
    );
}

1;
