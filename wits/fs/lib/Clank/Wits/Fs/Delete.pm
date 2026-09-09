# CLANK-WIT: name=Delete
# CLANK-WIT: version=1.0.0
# CLANK-WIT: about=Delete file with backup before removal
# CLANK-WIT: usage=Input: { path: "/tmp/test.txt", backup: true } Output: { ok: true, backup: "/tmp/clam_backups/test.txt.20250629" }
# CLANK-WIT: hint=Creates backup before deletion. Supports dry_run to preview.
# CLANK-WIT: author=Clank
# CLANK-WIT: license=Artistic-2.0
package Clank::Wits::Fs::Delete;
use strict;
use warnings;
use File::Path qw(make_path);
use File::Copy qw(copy);
use POSIX qw(strftime);

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'fs_delete',
        description => 'Delete file with backup before removal',
        parameters  => {
            type       => 'object',
            properties => {
                path    => { type => 'string', description => 'File path to delete' },
                backup  => { type => 'boolean', description => 'Create backup before deletion', default => \1 },
                dry_run => { type => 'boolean', description => 'Preview deletion without executing', default => 0 },
            },
            required => ['path'],
        },
        execute => sub {
            my ($args) = @_;
            my $path = $args->{path} // '';
            my $backup = $args->{backup} // 1;
            my $dry_run = $args->{dry_run} // 0;

            return { error => "No path provided" } unless $path;
            return { error => "Path contains .." } if $path =~ /\.\./;
            return { error => "File not found: $path" } unless -f $path;

            if ($dry_run) {
                return {
                    ok           => 0,
                    dry_run      => 1,
                    would_delete => $path,
                };
            }

            if ($backup) {
                my $backup_dir = '/tmp/clam_backups';
                make_path($backup_dir) unless -d $backup_dir;
                my $backup_name = "$path." . strftime("%Y%m%d_%H%M%S", localtime);
                $backup_name =~ s{^/}{};
                $backup_name = "$backup_dir/$backup_name";
                copy($path, $backup_name) or warn "Backup failed: $!";
            }

            unlink $path or return { error => "Delete failed: $!" };

            return {
                ok   => 1,
                path => $path,
            };
        },
    );
}

1;
