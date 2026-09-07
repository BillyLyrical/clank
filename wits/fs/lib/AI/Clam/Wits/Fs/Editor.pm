# CLAM-WIT: name=Editor
# CLAM-WIT: version=1.0.0
# CLAM-WIT: about=Open $EDITOR for editing files or text blocks — vim, nano, etc.
# CLAM-WIT: usage=Input: { file: "lib/Foo.pm" } Input: { content: "sub foo { }" } Input: { file: "/tmp/block.txt", content: "# Edit this:\n" } Output: { ok: true, content: "...", changed: true }
# CLAM-WIT: hint=Spawns $EDITOR (vim, nano, etc.) for interactive editing. Works with files or temporary text blocks. Returns edited content for further processing.
# CLAM-WIT: author=CLAM
# CLAM-WIT: license=Artistic-2.0
package AI::Clam::Wits::Fs::Editor;
use strict;
use warnings;
use File::Temp;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'fs_editor',
        description => 'Open $EDITOR for editing files or text blocks',
        parameters  => {
            type       => 'object',
            properties => {
                file    => { type => 'string', description => 'File path to edit' },
                content => { type => 'string', description => 'Content to edit (creates temp file)' },
                suffix  => { type => 'string', description => 'Suffix for temp file', default => '.txt' },
            },
        },
        execute => sub {
            my ($args) = @_;
            my $file = $args->{file} // '';
            my $content = $args->{content} // '';
            my $suffix = $args->{suffix} // '.txt';

            my $editor = $ENV{EDITOR} || $ENV{VISUAL} || 'vi';
            my $temp_file = '';

            if ($file) {
                return { error => "File not found: $file" } unless -f $file;

                my $before = eval { local $/; open my $fh, '<', $file or die; <$fh> };

                system($editor, $file);
                my $exit = $? >> 8;

                my $after = eval { local $/; open my $fh, '<', $file or die; <$fh> };
                my $changed = defined($before) && defined($after) && $before ne $after;

                return {
                    topic   => 'fs.editor',
                    ok      => $exit == 0,
                    file    => $file,
                    content => $after,
                    changed => $changed,
                };
            }

            if ($content || !$file) {
                my $fh = File::Temp->new(SUFFIX => $suffix, UNLINK => 0);
                $temp_file = $fh->filename;
                print $fh $content if $content;
                close $fh;

                system($editor, $temp_file);
                my $exit = $? >> 8;

                my $result = eval { local $/; open my $rfh, '<', $temp_file or die; <$rfh> };
                unlink $temp_file;

                my $changed = defined($result) && $result ne $content;

                return {
                    topic   => 'fs.editor',
                    ok      => $exit == 0,
                    content => $result,
                    changed => $changed,
                    temp    => 1,
                };
            }

            return { error => "No file or content specified" };
        },
    );
}

1;
