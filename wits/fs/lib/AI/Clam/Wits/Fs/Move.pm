# CLAM-WIT: name=Move
# CLAM-WIT: version=1.0.0
# CLAM-WIT: about=Move/rename file with backup
# CLAM-WIT: usage=Input: { source: "/path/a.txt", dest: "/path/b.txt" } Output: { ok: true }
# CLAM-WIT: hint=Backs up destination if it exists.
# CLAM-WIT: author=CLAM
# CLAM-WIT: license=Artistic-2.0
package AI::Clam::Wits::Fs::Move;
use strict;
use warnings;
use File::Path qw(make_path);
use File::Copy qw(copy);
use POSIX qw(strftime);

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'fs_move',
        description => 'Move/rename file with backup',
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
            return { error => "Source not found: $source" } unless -e $source;
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

            rename $source, $dest or return { error => "Move failed: $!" };

            return {
                ok     => 1,
                source => $source,
                dest   => $dest,
            };
        },
    );
}

1;
