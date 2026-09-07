# CLAM-WIT: name=Security
# CLAM-WIT: version=1.0.0
# CLAM-WIT: about=Find unsafe Perl patterns (system, eval, no taint)
# CLAM-WIT: usage=Input: { code: "system($user_input); eval $code;" } Output: { issues: [{ type: "taint", msg: "...", severity: "critical" }] }
# CLAM-WIT: hint=perl_security, security, taint mode, unsafe patterns
# CLAM-WIT: author=CLAM
# CLAM-WIT: license=Artistic-2.0
package AI::Clam::Wits::Perl::Security;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'perl_security',
        description => 'Find unsafe Perl patterns (system, eval, no taint)',
        parameters  => {
            type       => 'object',
            properties => {
                code => { type => 'string', description => 'Perl code to analyze' },
            },
            required => ['code'],
        },
        execute => sub {
            my ($args) = @_;
            my $code = $args->{code} // '';

            return { issues => [] } unless $code;

            my @issues;

            if ($code =~ /\bsystem\s*\((?:\$[^)]+)\)/) {
                push @issues, {
                    type       => 'taint',
                    severity   => 'critical',
                    msg        => 'Untainted data in system() — use list form or IPC::Run',
                    suggestion => 'IPC::Run::run("cmd", \$input)',
                };
            }

            if ($code =~ /\bexec\s*\((?:\$[^)]+)\)/) {
                push @issues, {
                    type       => 'taint',
                    severity   => 'critical',
                    msg        => 'Untainted data in exec() — use list form',
                    suggestion => 'exec("cmd", @args)',
                };
            }

            if ($code =~ /\beval\s+(?:\$[^{])/) {
                push @issues, {
                    type       => 'taint',
                    severity   => 'critical',
                    msg        => 'Eval of untainted data — use Safe compartment',
                    suggestion => 'Safe->new->reval($code)',
                };
            }

            if ($code =~ /\bdo\s+['"]/) {
                push @issues, {
                    type     => 'unsafe',
                    severity => 'high',
                    msg      => 'do with filename — potential code injection',
                };
            }

            if ($code =~ /\brequire\s+\$/) {
                push @issues, {
                    type     => 'unsafe',
                    severity => 'high',
                    msg      => 'require with variable — potential code injection',
                };
            }

            if ($code =~ /\bopen\s*\(\s*\w+\s*,[^>]*\$\w+/) {
                push @issues, {
                    type     => 'unsafe',
                    severity => 'medium',
                    msg      => 'open with variable — check file permissions',
                };
            }

            if ($code =~ /\bchmod\b.*\$\w+/) {
                push @issues, {
                    type     => 'unsafe',
                    severity => 'medium',
                    msg      => 'chmod with variable — verify permissions',
                };
            }

            return { issues => \@issues };
        },
    );
}

1;
