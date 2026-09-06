# CLAM-WIT: name=Pipe
# CLAM-WIT: version=1.0.0
# CLAM-WIT: about=Pipe data through a command
# CLAM-WIT: usage=Input: { data: "hello world", cmd: "tr '[:lower:]' '[:upper:]'" } Output: { result: "HELLO WORLD", exit: 0 }
# CLAM-WIT: hint=Feeds data to command's stdin.
# CLAM-WIT: author=CLAM
# CLAM-WIT: license=Artistic-2.0
package Clam::Wits::Fs::Pipe;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'fs_pipe',
        description => 'Pipe data through a command',
        parameters  => {
            type       => 'object',
            properties => {
                data => { type => 'string', description => 'Data to pipe to command' },
                cmd  => { type => 'string', description => 'Shell command to execute' },
            },
            required => ['data', 'cmd'],
        },
        execute => sub {
            my ($args) = @_;
            my $data = $args->{data} // '';
            my $cmd = $args->{cmd} // '';

            return { error => "No data or command provided" } unless $data && $cmd;

            open my $fh, '|-', $cmd or return { error => "Cannot pipe: $!" };
            print $fh $data;
            close $fh;

            my $exit = $? >> 8;

            return {
                result => $data,
                exit   => $exit,
                cmd    => $cmd,
            };
        },
    );
}

1;
