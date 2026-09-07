package AI::Clam::Tools::Edit;
use strict; use warnings;
use parent 'AI::Clam::Tool';
# Pi-parity edit tool: exact text replacement. Every edits[].oldText must match a
# unique, non-overlapping region of the ORIGINAL file (all matched before any applied).

sub new {
    my ($class, %o) = @_;
    return $class->SUPER::new(
        name => 'edit',
        description => "Edit a single file using exact text replacement. Every edits[].oldText must match a unique, non-overlapping region of the original file. If two changes affect the same block or nearby lines, merge them into one edit instead of emitting overlapping edits. Do not include large unchanged regions just to connect distant changes.",
        parameters => {
            type => 'object',
            properties => {
                path => { type => 'string', description => 'Path to the file to edit (relative or absolute)' },
                edits => {
                    type => 'array',
                    items => {
                        type => 'object',
                        required => ['oldText','newText'],
                        properties => {
                            oldText => { type => 'string', description => 'Exact text for one targeted replacement. It must be unique in the original file and must not overlap with any other edits[].oldText in the same call.' },
                            newText => { type => 'string', description => 'Replacement text for this targeted edit.' },
                        },
                    },
                    description => 'One or more targeted replacements. Each edit is matched against the original file, not incrementally. Do not include overlapping or nested edits. Merge nearby changes into one edit instead.',
                },
            },
            required => ['path','edits'],
        },
    );
}

sub execute {
    my ($self, $args) = @_;
    my $path  = $args->{path}  or return err('path is required');
    my $edits = $args->{edits};
    return err('edits[] is required') unless ref $edits eq 'ARRAY' && @$edits;
    return err("no such file: $path") unless -f $path;

    open my $fh, '<:raw', $path or return err("open $path: $!");
    local $/; my $content = <$fh>; close $fh;

    # 1) locate every edit in the ORIGINAL content
    my @spans;
    for my $i (0 .. $#$edits) {
        my ($old, $new) = ($edits->[$i]{oldText}, $edits->[$i]{newText});
        return err("edit #$i: oldText is empty") unless defined $old && length $old;
        $new //= '';
        my @pos;
        my $idx = index($content, $old);
        while ($idx >= 0) { push @pos, $idx; $idx = index($content, $old, $idx + 1); }
        return err("edit #$i: oldText not found in file") unless @pos;
        return err("edit #$i: oldText is not unique (" . scalar(@pos) . " matches)") if @pos > 1;
        push @spans, [ $pos[0], length($old), $new ];
    }

    # 2) overlap check
    my @sorted = sort { $a->[0] <=> $b->[0] } @spans;
    for my $i (1 .. $#sorted) {
        my ($p0,$l0) = @{$sorted[$i-1]}[0,1];
        my ($p1)     = @{$sorted[$i]}[0];
        if ($p1 < $p0 + $l0) {
            return err("edits overlap: edit spans intersect (offsets " . ($p0+1) . "-" . ($p0+$l0) . " and " . ($p1+1) . "). Merge them into one edit.");
        }
    }

    # 3) apply back-to-front
    for my $s (reverse @sorted) {
        my ($pos, $len, $new) = @$s;
        substr($content, $pos, $len) = $new;
    }

    open my $out, '>:raw', $path or return err("write $path: $!");
    print {$out} $content; close $out;
    return { output => "Successfully replaced " . scalar(@spans) . " block(s) in $path", isError => 0 };
}

sub err { my ($m)=@_; return { output => "error: $m", isError => 1 }; }
1;
