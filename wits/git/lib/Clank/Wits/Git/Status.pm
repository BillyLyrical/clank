# CLANK-WIT: name=Status
# CLANK-WIT: version=1.0.0
# CLANK-WIT: about=Show git status
# CLANK-WIT: usage=Input: { path: "." } Output: { clean: false, modified: [...], untracked: [...] }
# CLANK-WIT: hint=git status, working tree, modified files, untracked files, staged changes
# CLANK-WIT: author=Clank
# CLANK-WIT: license=Artistic-2.0
package Clank::Wits::Git::Status;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'git_status',
        description => 'Show git status',
        parameters  => {
            type       => 'object',
            properties => {
                path => { type => 'string', description => 'Repository path', default => '.' },
            },
        },
        execute => sub {
            my ($args) = @_;
            my $path = $args->{path} // '.';

            my $output = `cd '$path' && git status --porcelain 2>/dev/null`;
            my $exit = $? >> 8;

            return { error => "Not a git repository" } if $exit != 0;

            my (@modified, @untracked, @staged);
            for my $line (split /\n/, $output) {
                my ($status, $file) = $line =~ /^(.)(.)\s+(.+)$/;
                next unless $file;

                if ($status eq '?') {
                    push @untracked, $file;
                } elsif ($status eq 'M' || $status eq 'A' || $status eq 'D') {
                    push @staged, { status => $status, file => $file };
                } elsif ($status eq ' ') {
                    push @modified, $file if $2 eq 'M';
                }
            }

            return {
                clean     => !@modified && !@untracked && !@staged,
                modified  => \@modified,
                untracked => \@untracked,
                staged    => \@staged,
                path      => $path,
            };
        },
    );
}

1;
