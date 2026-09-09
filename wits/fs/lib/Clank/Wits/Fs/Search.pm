# CLANK-WIT: name=Search
# CLANK-WIT: version=1.0.0
# CLANK-WIT: about=Search for files by pattern or content
# CLANK-WIT: usage=Input: { path: ".", pattern: "*.wit", contains: "source" } Output: { files: [...], count: 5 }
# CLANK-WIT: hint=Read-only. Finds files matching criteria.
# CLANK-WIT: author=Clank
# CLANK-WIT: license=Artistic-2.0
package Clank::Wits::Fs::Search;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'fs_search',
        description => 'Search for files by pattern or content',
        parameters  => {
            type       => 'object',
            properties => {
                path     => { type => 'string', description => 'Search path', default => '.' },
                pattern  => { type => 'string', description => 'Filename pattern (glob)', default => '*' },
                contains => { type => 'string', description => 'Content to search for in files', default => '' },
            },
        },
        execute => sub {
            my ($args) = @_;
            my $path = $args->{path} // '.';
            my $pattern = $args->{pattern} // '*';
            my $contains = $args->{contains} // '';

            return { error => "Path contains .." } if $path =~ /\.\./;
            return { error => "Not a directory: $path" } unless -d $path;

            my $cmd = "find $path -name '$pattern' -type f 2>/dev/null";
            my @files = `$cmd`;
            chomp @files;

            my @matches;
            for my $file (@files) {
                if ($contains) {
                    open my $fh, '<', $file or next;
                    my $content = do { local $/; <$fh> };
                    close $fh;
                    next unless $content =~ /\Q$contains\E/;
                }
                push @matches, {
                    path => $file,
                    size => -s $file,
                };
            }

            return {
                files       => \@matches,
                count       => scalar @matches,
                search_path => $path,
                pattern     => $pattern,
                contains    => $contains,
            };
        },
    );
}

1;
