# CLANK-WIT: name=Stacktrace
# CLANK-WIT: version=1.0.0
# CLANK-WIT: about=Get Perl stack trace from a running process or script
# CLANK-WIT: usage=Input: { pid: 1234 } Output: { ok: true, trace: "..." }
# CLANK-WIT: hint=perl stack trace, backtrace, process debug, gdb
# CLANK-WIT: author=Clank
# CLANK-WIT: license=Artistic-2.0
package Clank::Wits::Debug::Stacktrace;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;
    $api->register_tool(
        name        => 'debug_stacktrace',
        description => 'Get Perl stack trace from a running process or script',
        parameters  => {
            type       => 'object',
            properties => {
                pid  => { type => 'integer', description => 'Process ID to trace' },
                file => { type => 'string', description => 'Script file to run with debug' },
            },
        },
        execute => sub {
            my ($args) = @_;
            my $pid  = $args->{pid};
            my $file = $args->{file} // '';

            if ($pid) {
                my $cmd = "kill -USR1 $pid 2>&1";
                my $output = `$cmd`;
                my $exit_code = $? >> 8;

                if ($exit_code == 0) {
                    return {
                        ok     => 1,
                        message => "Sent SIGUSR1 to PID $pid (stack trace written to STDERR)",
                        pid    => $pid,
                    };
                }
                else {
                    return { error => "Failed to signal PID $pid: $output", exit_code => $exit_code };
                }
            }
            elsif ($file) {
                return { error => "File not found: $file" } unless -f $file;

                my $cmd = "perl -MCarp=Always $file 2>&1";
                my $output = `$cmd`;
                my $exit_code = $? >> 8;

                return {
                    ok        => $exit_code == 0 ? 1 : 0,
                    output    => $output,
                    exit_code => $exit_code,
                    file      => $file,
                };
            }
            else {
                return { error => "Provide either pid or file" };
            }
        },
    );
}

1;
