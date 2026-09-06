# CLAM-WIT: name=Edit
# CLAM-WIT: version=1.0.0
# CLAM-WIT: about=Edit file with backup and atomic operation
# CLAM-WIT: usage=Input: { path: "/tmp/test.txt", search: "old", replace: "new" } Output: { ok: true, replacements: 3 }
# CLAM-WIT: hint=Creates backup before edit. Atomic: edit to temp, then rename.
# CLAM-WIT: author=CLAM
# CLAM-WIT: license=Artistic-2.0
package Clam::Wits::Fs::Edit;
use strict;
use warnings;
use File::Path qw(make_path);
use File::Copy qw(copy);
use POSIX qw(strftime);

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'fs_edit',
        description => 'Edit file with backup and atomic operation',
        parameters  => {
            type       => 'object',
            properties => {
                path    => { type => 'string', description => 'File path to edit' },
                search  => { type => 'string', description => 'Text to search for' },
                replace => { type => 'string', description => 'Replacement text' },
                backup  => { type => 'boolean', description => 'Create backup before edit', default => \1 },
            },
            required => ['path', 'search', 'replace'],
        },
        execute => sub {
            my ($args) = @_;
            my $path = $args->{path} // '';
            my $search = $args->{search} // '';
            my $replace = $args->{replace} // '';
            my $backup = $args->{backup} // 1;

            return { error => "No path provided" } unless $path;
            return { error => "No search term" } unless $search;
            return { error => "Path contains .." } if $path =~ /\.\./;
            return { error => "File not found: $path" } unless -f $path;

            if ($backup) {
                my $backup_dir = '/tmp/clam_backups';
                make_path($backup_dir) unless -d $backup_dir;
                my $backup_name = "$path." . strftime("%Y%m%d_%H%M%S", localtime);
                $backup_name =~ s{^/}{};
                $backup_name = "$backup_dir/$backup_name";
                copy($path, $backup_name) or warn "Backup failed: $!";
            }

            open my $fh, '<', $path or return { error => "Cannot read: $!" };
            my $content = do { local $/; <$fh> };
            close $fh;

            my $count = () = $content =~ /\Q$search\E/g;
            $content =~ s/\Q$search\E/$replace/g;

            my $tmp = "$path.tmp.$$";
            open my $fh2, '>', $tmp or return { error => "Cannot write: $!" };
            print $fh2 $content;
            close $fh2;

            rename $tmp, $path or return { error => "Cannot rename: $!" };

            return {
                ok           => 1,
                path         => $path,
                replacements => $count,
            };
        },
    );
}

1;
