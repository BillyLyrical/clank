# CLANK-WIT: name=Read
# CLANK-WIT: version=1.0.0
# CLANK-WIT: about=Read file contents safely (read-only)
# CLANK-WIT: usage=Input: { path: "/home/user/file.txt", max_size: 1048576 } Output: { content: "...", size: 1234, lines: 50 }
# CLANK-WIT: hint=Read-only. Validates path, checks size limit. No write operations.
# CLANK-WIT: author=Clank
# CLANK-WIT: license=Artistic-2.0
package Clank::Wits::Fs::Read;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'fs_read',
        description => 'Read file contents safely (read-only)',
        parameters  => {
            type       => 'object',
            properties => {
                path     => { type => 'string', description => 'File path to read' },
                max_size => { type => 'integer', description => 'Maximum file size in bytes', default => 1048576 },
            },
            required => ['path'],
        },
        execute => sub {
            my ($args) = @_;
            my $path = $args->{path} // '';
            my $max_size = $args->{max_size} // 1048576;

            return { error => "No path provided" } unless $path;

            return { error => "Path contains .." } if $path =~ /\.\./;
            return { error => "Path is absolute" } unless $path =~ m{^/} || $path =~ m{^\./};

            return { error => "File not found: $path" } unless -f $path;

            my $size = -s $path;
            return { error => "File too large: $size bytes (max $max_size)" } if $size > $max_size;

            open my $fh, '<', $path or return { error => "Cannot read: $!" };
            my $content = do { local $/; <$fh> };
            close $fh;

            my @lines = split /\n/, $content;

            return {
                content => $content,
                size    => $size,
                lines   => scalar @lines,
                path    => $path,
            };
        },
    );
}

1;
