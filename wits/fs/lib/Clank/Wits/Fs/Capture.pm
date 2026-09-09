# CLANK-WIT: name=Capture
# CLANK-WIT: version=1.0.0
# CLANK-WIT: about=Capture command output separately (stdout/stderr)
# CLANK-WIT: usage=Input: { cmd: "perl -e 'print 1'" } Output: { stdout: "1", stderr: "", exit: 0 }
# CLANK-WIT: hint=Separates stdout and stderr.
# CLANK-WIT: author=Clank
# CLANK-WIT: license=Artistic-2.0
package Clank::Wits::Fs::Capture;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'fs_capture',
        description => 'Capture command output separately (stdout/stderr)',
        parameters  => {
            type       => 'object',
            properties => {
                cmd => { type => 'string', description => 'Shell command to execute' },
            },
            required => ['cmd'],
        },
        execute => sub {
            my ($args) = @_;
            my $cmd = $args->{cmd} // '';

            return { error => "No command provided" } unless $cmd;

            my $stdout = `$cmd 2>/tmp/clam_stderr_$$`;
            my $exit = $? >> 8;

            my $stderr = '';
            if (-f "/tmp/clam_stderr_$$") {
                open my $fh, '<', "/tmp/clam_stderr_$$";
                $stderr = do { local $/; <$fh> };
                close $fh;
                unlink "/tmp/clam_stderr_$$";
            }

            return {
                stdout => $stdout,
                stderr => $stderr,
                exit   => $exit,
                cmd    => $cmd,
            };
        },
    );
}

1;
