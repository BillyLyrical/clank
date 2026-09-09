# CLANK-WIT: name=Commit
# CLANK-WIT: version=1.0.0
# CLANK-WIT: about=Stage and commit changes
# CLANK-WIT: usage=Input: { path: ".", message: "commit message", files: ["file1.txt"] } Output: { ok: true, hash: "abc123" }
# CLANK-WIT: hint=git commit, stage files, create commit
# CLANK-WIT: author=Clank
# CLANK-WIT: license=Artistic-2.0
package Clank::Wits::Git::Commit;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'git_commit',
        description => 'Stage and commit changes',
        parameters  => {
            type       => 'object',
            properties => {
                path    => { type => 'string', description => 'Repository path', default => '.' },
                message => { type => 'string', description => 'Commit message' },
                files   => { type => 'array', items => { type => 'string' }, description => 'Files to stage (empty = all)' },
            },
            required => ['message'],
        },
        execute => sub {
            my ($args) = @_;
            my $path = $args->{path} // '.';
            my $message = $args->{message} // '';
            my $files = $args->{files} // [];

            return { error => "No commit message" } unless $message;

            # Stage files
            if (@$files) {
                for my $file (@$files) {
                    system("cd '$path' && git add '$file'");
                }
            } else {
                system("cd '$path' && git add -A");
            }

            # Commit
            my $output = `cd '$path' && git commit -m '$message' 2>&1`;
            my $exit = $? >> 8;

            return { error => "Commit failed: $output" } if $exit != 0;

            # Get commit hash
            my $hash = `cd '$path' && git rev-parse --short HEAD`;
            chomp $hash;

            return {
                ok      => 1,
                hash    => $hash,
                message => $message,
                path    => $path,
            };
        },
    );
}

1;
