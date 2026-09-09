# CLANK-WIT: name=Lsof
# CLANK-WIT: version=1.0.0
# CLANK-WIT: about=List open files for a process or all processes
# CLANK-WIT: usage=Input: { pid: 1234, type: "txt" } Output: { files: [{ fd: "3r", type: "txt", name: "/path/file" }] }
# CLANK-WIT: hint=lsof, open files, file descriptors, process files
# CLANK-WIT: author=Clank
# CLANK-WIT: license=Artistic-2.0
package Clank::Wits::Debug::Lsof;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;
    $api->register_tool(
        name        => 'debug_lsof',
        description => 'List open files for a process or all processes',
        parameters  => {
            type       => 'object',
            properties => {
                pid      => { type => 'integer', description => 'Process ID' },
                type     => { type => 'string', enum => ['txt', 'reg', 'DIR', 'CHR', 'FIFO'], description => 'File type filter' },
                name     => { type => 'string', description => 'Name pattern to match' },
                command  => { type => 'string', description => 'Command name to match' },
            },
        },
        execute => sub {
            my ($args) = @_;
            my $pid     = $args->{pid};
            my $type    = $args->{type}    // '';
            my $name    = $args->{name}    // '';
            my $command = $args->{command} // '';

            my $cmd = "lsof";
            $cmd .= " -p $pid" if $pid;
            $cmd .= " -a -t $type" if $type;
            $cmd .= " -a -s TCP:LISTEN" if $command && $command eq 'listen';
            $cmd .= " 2>&1";

            my $output = `$cmd`;
            my $exit_code = $? >> 8;

            if ($exit_code != 0 && $output =~ /No such process/) {
                return { error => "Process not found: $pid", exit_code => $exit_code };
            }

            my @files;
            my @lines = split /\n/, $output;
            shift @lines if @lines && $lines[0] =~ /^COMMAND/;

            for my $line (@lines) {
                my @f = split /\s+/, $line;
                push @files, {
                    command => $f[0],
                    pid     => $f[1],
                    user    => $f[2],
                    fd      => $f[3],
                    type    => $f[4],
                    device  => $f[5],
                    size    => $f[6],
                    name    => $f[8] // '',
                };
            }

            return {
                ok    => 1,
                files => \@files,
                count => scalar @files,
            };
        },
    );
}

1;
