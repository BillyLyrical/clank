package Clank::Tools::Read;
use strict; use warnings;
use parent 'Clank::Tool';
# Pi-parity read tool: text (truncated 2000 lines / 50KB) + image detection.

my $MAX_LINES = 2000;
my $MAX_BYTES = 50 * 1024;

sub new {
    my ($class, %o) = @_;
    return $class->SUPER::new(
        name => 'read',
        description => "Read the contents of a file. Supports text files and images (jpg, png, gif, webp, bmp). Images are sent as attachments. For text files, output is truncated to 2000 lines or 50KB (whichever is hit first). Use offset/limit for large files. If you need the full file, continue with offset until complete.",
        parameters => {
            type => 'object',
            properties => {
                path   => { type => 'string', description => 'Path to the file to read (relative or absolute)' },
                offset => { type => 'number', description => 'Line number to start reading from (1-indexed)' },
                limit  => { type => 'number', description => 'Maximum number of lines to read' },
            },
            required => ['path'],
        },
    );
}

sub execute {
    my ($self, $a) = @_;
    my $path = $a->{path} or return err('path is required');
    return err("no such file: $path") unless -e $path;
    return err("is a directory: $path") if -d $path;

    # image detection by extension (v1: no vision, report metadata)
    if ($path =~ /\.(jpe?g|png|gif|webp|bmp)$/i) {
        my $size = -s $path;
        return { output => "[image file: $path ($size bytes)] (vision not enabled in this build)", isError => 0 };
    }

    open my $fh, '<:raw', $path or return err("open $path: $!");
    my @lines = <$fh>; close $fh;
    s/\r?\n$// for @lines;

    my $total_lines = scalar @lines;
    my $offset = ($a->{offset} // 1) - 1; $offset = 0 if $offset < 0;
    my $limit  = $a->{limit}  // $MAX_LINES;
    $limit = $MAX_LINES if $limit > $MAX_LINES;

    # clamp range to available lines (perl slices pad with undef otherwise)
    my $end = $offset + $limit - 1;
    $end = $total_lines - 1 if $end > $total_lines - 1;
    my @sel = ($offset < $total_lines && $end >= $offset) ? @lines[$offset .. $end] : ();

    # byte cap: drop trailing lines until under MAX_BYTES
    my $total = 0; $total += length($_) + 1 for @sel;
    while (@sel && $total > $MAX_BYTES) { $total -= length(pop @sel) + 1; }

    my $out = join("\n", map { defined $_ ? $_ : '' } @sel);
    # note only when the implicit cap was hit (explicit limit means user chose the range)
    my $note = '';
    if (!defined $a->{limit} && $offset + @sel < $total_lines) {
        $note = "\n[... truncated: showing lines " . ($offset+1) . "-" . ($offset+@sel) . " of $total_lines]";
    }
    return { output => length($out) ? $out.$note : "(empty file or offset past end)", isError => 0 };
}

sub err { my ($m)=@_; return { output => "error: $m", isError => 1 }; }
1;
