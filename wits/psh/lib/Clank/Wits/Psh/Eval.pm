# CLANK-WIT: name=Eval
# CLANK-WIT: version=1.1.0
# CLANK-WIT: about=Execute Perl code or shell commands — syntax check, eval, capture result. psh_sandbox runs code in a subprocess for isolation.
# CLANK-WIT: usage=Input: { code: "use Clank::Auth; my $auth = Clank::Auth->new" } or { code: "!ls -la" } Output: { ok: true, result: "...", type: "perl"|"shell" }
# CLANK-WIT: hint=psh_eval, psh_sandbox, eval, execute, shell, perl, REPL, sandbox, isolated, subprocess
# CLANK-WIT: author=Clank
# CLANK-WIT: license=Artistic-2.0
package Clank::Wits::Psh::Eval;
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

                    sub clank {
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

    # psh_sandbox: runs Perl code in a subprocess via Clank::Exec.
    # No state persistence between calls — each execution is isolated.
    # Use for untrusted code, testing crystallized rules, or anything
    # that might segfault/infinite-loop/crash.
    $api->register_tool(
        name        => 'psh_sandbox',
        description => 'Execute Perl code in an isolated subprocess. No state persists between calls. Use for untrusted code or testing.',
        parameters  => {
            type       => 'object',
            properties => {
                code    => { type => 'string', description => 'Perl code to execute' },
                timeout => { type => 'number', description => 'Timeout in seconds (default 30)' },
            },
            required => ['code'],
        },
        execute => sub {
            my ($args) = @_;
            my $code    = $args->{code}    // '';
            my $timeout = $args->{timeout} // 30;

            return { ok => 0, error => "No code provided" } unless $code;

            require Clank::Exec;
            my $r = Clank::Exec::exec_cmd(
                command => ['perl', '-e', $code],
                timeout => $timeout,
            );

            if ($r->{isError}) {
                return { ok => 0, error => $r->{error} };
            }
            if ($r->{timed_out}) {
                return { ok => 0, error => "timed out after ${timeout}s" };
            }

            my $stdout = $r->{stdout} // '';
            my $stderr = $r->{stderr} // '';
            chomp $stdout;
            chomp $stderr;

            return {
                ok       => $r->{exit_code} == 0,
                result   => $stdout,
                stderr   => $stderr,
                exit     => $r->{exit_code},
                type     => 'perl_sandbox',
            };
        },
    );
}

1;
