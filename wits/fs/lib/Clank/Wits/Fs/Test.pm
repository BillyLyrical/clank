# CLANK-WIT: name=Test
# CLANK-WIT: version=1.0.0
# CLANK-WIT: about=File test operations — existence, permissions, type, age
# CLANK-WIT: usage=Input: { path: "/home/user/file.txt" } Output: { exists: true, type: "file", readable: true, executable: false, ... }
# CLANK-WIT: hint=Read-only. Wraps Perl file test operators: -e -f -d -l -r -w -x -o -s -M -A -C
# CLANK-WIT: author=Clank
# CLANK-WIT: license=Artistic-2.0
package Clank::Wits::Fs::Test;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'fs_test',
        description => 'File test operations — existence, permissions, type, age',
        parameters  => {
            type       => 'object',
            properties => {
                path => { type => 'string', description => 'File path to test' },
            },
            required => ['path'],
        },
        execute => sub {
            my ($args) = @_;
            my $path = $args->{path} // '';

            return { error => "No path provided" } unless $path;

            my $exists = -e $path;

            my %result = (
                exists => $exists,
                path   => $path,
            );

            if ($exists) {
                my $type = 'other';
                $type = 'file'      if -f _;
                $type = 'directory' if -d _;
                $type = 'symlink'   if -l _;
                $type = 'pipe'      if -p _;
                $type = 'socket'    if -S _;
                $type = 'block'     if -b _;
                $type = 'char'      if -c _;

                %result = (
                    %result,
                    type        => $type,
                    readable    => -r _,
                    writable    => -w _,
                    executable  => -x _,
                    owned       => -o _,
                    size        => -s _ // 0,
                    age_days    => sprintf("%.2f", -M _),
                    access_days => sprintf("%.2f", -A _),
                    change_days => sprintf("%.2f", -C _),
                    symlink     => -l _,
                );
            } else {
                %result = (
                    %result,
                    type        => 'none',
                    readable    => 0,
                    writable    => 0,
                    executable  => 0,
                    owned       => 0,
                    size        => 0,
                    age_days    => undef,
                    access_days => undef,
                    change_days => undef,
                    symlink     => 0,
                );
            }

            return \%result;
        },
    );
}

1;
