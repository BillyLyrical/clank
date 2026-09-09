# CLANK-WIT: name=Write
# CLANK-WIT: version=1.0.0
# CLANK-WIT: about=Write file with backup and atomic operation
# CLANK-WIT: usage=Input: { path: "/tmp/test.txt", content: "hello", backup: true } Output: { ok: true, backup: "/tmp/clam_backups/test.txt.20250629", bytes: 5 }
# CLANK-WIT: hint=Creates backup before write. Atomic: write to temp, then rename.
# CLANK-WIT: author=Clank
# CLANK-WIT: license=Artistic-2.0
package Clank::Wits::Fs::Write;
use strict;
use warnings;
use File::Path qw(make_path);
use File::Copy qw(copy);
use POSIX qw(strftime);

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'fs_write',
        description => 'Write file with backup and atomic operation',
        parameters  => {
            type       => 'object',
            properties => {
                path    => { type => 'string', description => 'File path to write' },
                content => { type => 'string', description => 'Content to write' },
                backup  => { type => 'boolean', description => 'Create backup before write', default => \1 },
            },
            required => ['path', 'content'],
        },
        execute => sub {
            my ($args) = @_;
            my $path = $args->{path} // '';
            my $content = $args->{content} // '';
            my $backup = $args->{backup} // 1;

            return { error => "No path provided" } unless $path;
            return { error => "Path contains .." } if $path =~ /\.\./;

            if ($backup && -f $path) {
                my $backup_dir = '/tmp/clam_backups';
                make_path($backup_dir) unless -d $backup_dir;

                my $backup_name = "$path." . strftime("%Y%m%d_%H%M%S", localtime);
                $backup_name =~ s{^/}{};
                $backup_name = "$backup_dir/$backup_name";

                copy($path, $backup_name) or warn "Backup failed: $!";
            }

            my $tmp = "$path.tmp.$$";
            open my $fh, '>', $tmp or return { error => "Cannot write: $!" };
            print $fh $content;
            close $fh;

            rename $tmp, $path or return { error => "Cannot rename: $!" };

            return {
                ok    => 1,
                path  => $path,
                bytes => length($content),
            };
        },
    );
}

1;
