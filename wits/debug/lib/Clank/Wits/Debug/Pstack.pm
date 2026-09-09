# CLANK-WIT: name=Pstack
# CLANK-WIT: version=1.0.0
# CLANK-WIT: about=Print stack trace of a running process
# CLANK-WIT: usage=Input: { pid: 1234 } Output: { ok: true, trace: "..." }
# CLANK-WIT: hint=pstack, process stack, backtrace, running process debug
# CLANK-WIT: author=Clank
# CLANK-WIT: license=Artistic-2.0
package Clank::Wits::Debug::Pstack;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;
    $api->register_tool(
        name        => 'debug_pstack',
        description => 'Print stack trace of a running process',
        parameters  => {
            type       => 'object',
            properties => {
                pid => { type => 'integer', description => 'Process ID' },
            },
            required => ['pid'],
        },
        execute => sub {
            my ($args) = @_;
            my $pid = $args->{pid} // '';

            return { error => "No PID provided" } unless $pid;

            my $cmd = "pstack $pid 2>&1";
            my $output = `$cmd`;
            my $exit_code = $? >> 8;

            if ($exit_code != 0) {
                if ($output =~ /No such process/) {
                    return { error => "Process not found: $pid", exit_code => $exit_code };
                }
                return { error => "pstack failed: $output", exit_code => $exit_code };
            }

            return {
                ok     => 1,
                trace  => $output,
                pid    => $pid,
                frames => ($output =~ tr/\n//) + 1,
            };
        },
    );
}

1;
