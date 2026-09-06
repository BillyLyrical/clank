# CLAM-WIT: name=Eval
# CLAM-WIT: version=1.0.0
# CLAM-WIT: about=Execute Perl code or shell commands — syntax check, eval, capture result
# CLAM-WIT: usage=Input: { code: "use Clam::Auth; my $auth = Clam::Auth->new" } or { code: "!ls -la" } Output: { ok: true, result: "...", type: "perl"|"shell" }
# CLAM-WIT: hint=psh_eval, eval, execute, shell, perl, REPL
# CLAM-WIT: author=CLAM
# CLAM-WIT: license=Artistic-2.0
package Clam::Wits::Psh::Eval;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'psh_eval',
        description => 'Execute Perl code or shell commands — syntax check, eval, capture result',
        parameters  => {
            type       => 'object',
            properties => {
                code => { type => 'string', description => 'Perl code or shell command (prefix with !)' },
            },
            required => ['code'],
        },
        execute => sub {
            my ($args) = @_;
            my $code = $args->{code} // '';
            my %ctx = $args->{_ctx} ? %{$args->{_ctx}} : ();

            return { ok => 0, error => "No code provided" } unless $code;

            my $state = $ctx{state} // {};
            $state->{psh} //= { vars => {}, history => [], result => '' };

            if ($code =~ /^\s*!(.*)$/) {
                my $cmd = $1;
                my $output = `$cmd 2>&1`;
                my $exit = $? >> 8;

                $state->{psh}{result} = $output;
                push @{$state->{psh}{history}}, {
                    code   => $code,
                    result => $output,
                    type   => 'shell',
                    time   => time(),
                };

                return {
                    ok     => $exit == 0,
                    result => $output,
                    exit   => $exit,
                    type   => 'shell',
                };
            }

            my $escaped = $code;
            $escaped =~ s/'/\\'/g;
            my $check_cmd = "perl -c -e '$escaped' 2>&1";
            my $check_output = `$check_cmd`;
            my $check_exit = $? >> 8;

            if ($check_exit != 0) {
                return {
                    ok     => 0,
                    error  => $check_output,
                    type   => 'perl',
                    syntax_error => 1,
                };
            }

            my $vars_code = '';
            for my $var (keys %{$state->{psh}{vars}}) {
                my $val = $state->{psh}{vars}{$var};
                $val =~ s/\\/\\\\/g;
                $val =~ s/'/\\'/g;
                $vars_code .= "our \$$var = '$val';\n";
            }

            my $result = eval {
                my $clam_ref = $ctx{wits};
                my $full_code = qq{
                    package Psh;
                    no strict 'refs';

                    sub clam {
                        my (\$name, \$input) = \@_;
                        return \$clam_ref->execute(\$name, \$input) if \$clam_ref;
                        return { error => "No wits" };
                    }

                    $vars_code

                    $code

                    \$state->{psh}{result} = \$_ // '';
                };

                eval $full_code;
            };

            if ($@) {
                return {
                    ok     => 0,
                    error  => $@,
                    type   => 'perl',
                };
            }

            for my $sym (keys %main::) {
                next if $sym =~ /^_/;
                no strict 'refs';
                my $val = *{$sym}{SCALAR};
                if ($val && defined $$val) {
                    $state->{psh}{vars}{$sym} = $$val;
                }
            }

            my $final_result = $state->{psh}{result} // '';

            push @{$state->{psh}{history}}, {
                code   => $code,
                result => $final_result,
                type   => 'perl',
                time   => time(),
            };

            if (@{$state->{psh}{history}} > 100) {
                shift @{$state->{psh}{history}};
            }

            return {
                ok     => 1,
                result => "$final_result",
                ref    => ref($final_result),
                type   => 'perl',
            };
        },
    );
}

1;
