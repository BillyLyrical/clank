# CLANK-WIT: name=Strace
# CLANK-WIT: version=1.0.0
# CLANK-WIT: about=Trace system calls of a process
# CLANK-WIT: usage=Input: { pid: 1234, follow: true, output_file: "/tmp/trace.log" } Output: { ok: true, output: "..." }
# CLANK-WIT: hint=strace, system calls, trace process, syscall debugging
# CLANK-WIT: author=Clank
# CLANK-WIT: license=Artistic-2.0
package Clank::Wits::Debug::Strace;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;
    $api->register_tool(
        name        => 'debug_strace',
        description => 'Trace system calls of a process',
        parameters  => {
            type       => 'object',
            properties => {
                pid         => { type => 'integer', description => 'Process ID to trace' },
                command     => { type => 'string', description => 'Command to trace' },
                follow      => { type => 'boolean', description => 'Follow child processes', default => 0 },
                output_file => { type => 'string', description => 'Output file for trace' },
                filter      => { type => 'string', description => 'Filter syscalls (e.g. "read,write")' },
            },
        },
        execute => sub {
            my ($args) = @_;
            my $pid     = $args->{pid};
            my $command = $args->{command} // '';
            my $follow  = $args->{follow}  ? '-f' : '';
            my $outfile = $args->{output_file} // '';
            my $filter  = $args->{filter}  // '';

            my $cmd = "strace $follow";
            $cmd .= " -e $filter" if $filter;
            $cmd .= " -o $outfile" if $outfile;

            if ($pid) {
                $cmd .= " -p $pid";
            }
            elsif ($command) {
                $cmd .= " $command";
            }
            else {
                return { error => "Provide either pid or command" };
            }

            $cmd .= " 2>&1";

            my $output = `$cmd`;
            my $exit_code = $? >> 8;

            return {
                ok        => $exit_code == 0 ? 1 : 0,
                output    => $output,
                exit_code => $exit_code,
                pid       => $pid,
            };
        },
    );
}

1;
