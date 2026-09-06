# CLAM-WIT: name=Mkdir
# CLAM-WIT: version=1.0.0
# CLAM-WIT: about=Create directory safely
# CLAM-WIT: usage=Input: { path: "/tmp/new_dir" } Output: { ok: true, path: "/tmp/new_dir" }
# CLAM-WIT: hint=Creates directory and parents. Path validation included.
# CLAM-WIT: author=CLAM
# CLAM-WIT: license=Artistic-2.0
package Clam::Wits::Fs::Mkdir;
use strict;
use warnings;
use File::Path qw(make_path);

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'fs_mkdir',
        description => 'Create directory safely',
        parameters  => {
            type       => 'object',
            properties => {
                path => { type => 'string', description => 'Directory path to create' },
            },
            required => ['path'],
        },
        execute => sub {
            my ($args) = @_;
            my $path = $args->{path} // '';

            return { error => "No path provided" } unless $path;
            return { error => "Path contains .." } if $path =~ /\.\./;

            if (-d $path) {
                return { ok => 1, path => $path, exists => 1 };
            }

            make_path($path) or return { error => "Cannot create: $!" };

            return {
                ok   => 1,
                path => $path,
            };
        },
    );
}

1;
