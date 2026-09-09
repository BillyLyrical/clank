# CLANK-WIT: name=Copy
# CLANK-WIT: version=1.0.0
# CLANK-WIT: about=Copy file with backup of destination
# CLANK-WIT: usage=Input: { source: "/path/a.txt", dest: "/path/b.txt" } Output: { ok: true, bytes: 1234 }
# CLANK-WIT: hint=Backs up destination if it exists.
# CLANK-WIT: author=Clank
# CLANK-WIT: license=Artistic-2.0
package Clank::Wits::Fs::Copy;
use strict;
use warnings;
use File::Path qw(make_path);
use File::Copy qw(copy);
use POSIX qw(strftime);

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'fs_copy',
        description => 'Copy file with backup of destination',
        parameters  => {
            type       => 'object',
            properties => {
                source => { type => 'string', description => 'Source file path' },
                dest   => { type => 'string', description => 'Destination file path' },
            },
            required => ['source', 'dest'],
        },
        execute => sub {
            my ($args) = @_;
            my $source = $args->{source} // '';
            my $dest = $args->{dest} // '';

            return { error => "Source and dest required" } unless $source && $dest;
            return { error => "Source not found: $source" } unless -f $source;
            return { error => "Source contains .." } if $source =~ /\.\./;
            return { error => "Dest contains .." } if $dest =~ /\.\./;

            if (-f $dest) {
                my $backup_dir = '/tmp/clam_backups';
                make_path($backup_dir) unless -d $backup_dir;
                my $backup_name = "$dest." . strftime("%Y%m%d_%H%M%S", localtime);
                $backup_name =~ s{^/}{};
                $backup_name = "$backup_dir/$backup_name";
                copy($dest, $backup_name) or warn "Backup failed: $!";
            }

            copy($source, $dest) or return { error => "Copy failed: $!" };

            return {
                ok    => 1,
                source => $source,
                dest  => $dest,
                bytes => -s $dest,
            };
        },
    );
}

1;
