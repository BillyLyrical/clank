# CLAM-WIT: name=Diff
# CLAM-WIT: version=1.0.0
# CLAM-WIT: about=Show git diff
# CLAM-WIT: usage=Input: { path: ".", staged: false } Output: { diff: "...", lines_added: 10, lines_removed: 5 }
# CLAM-WIT: hint=git diff, show changes, working tree, staged changes
# CLAM-WIT: author=CLAM
# CLAM-WIT: license=Artistic-2.0
package Clam::Wits::Git::Diff;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'git_diff',
        description => 'Show git diff',
        parameters  => {
            type       => 'object',
            properties => {
                path   => { type => 'string', description => 'Repository path', default => '.' },
                staged => { type => 'boolean', description => 'Show staged changes', default => 0 },
            },
        },
        execute => sub {
            my ($args) = @_;
            my $path = $args->{path} // '.';
            my $staged = $args->{staged} // 0;

            my $cmd = $staged ? "cd '$path' && git diff --cached" : "cd '$path' && git diff";
            my $output = `$cmd 2>/dev/null`;
            my $exit = $? >> 8;

            return { error => "Not a git repository" } if $exit != 0 && !$output;

            my @lines = split /\n/, $output;
            my $added = grep { /^\+/ && !/^\+\+\+/ } @lines;
            my $removed = grep { /^\-/ && !/^\-\-\-/ } @lines;

            return {
                diff          => $output,
                lines_added   => $added,
                lines_removed => $removed,
                staged        => $staged,
                path          => $path,
            };
        },
    );
}

1;
