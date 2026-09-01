# Small shared helpers: ids, time, json, truncation, sizes.
package Clam::Util;
use strict;
use warnings;
use Exporter 'import';
use Digest::SHA qw(sha256_hex);
use JSON::PP ();

our @EXPORT_OK = qw(uuid4 now_ms jencode jdecode truncate_head truncate_tail format_size estimate_tokens ensure_dir);

my $JSON = JSON::PP->new->utf8->canonical->allow_nonref;

sub uuid4 {
    my @b = map { int(rand 256) } 1 .. 16;
    $b[6] = ($b[6] & 0x0f) | 0x40;   # version 4
    $b[8] = ($b[8] & 0x3f) | 0x80;   # variant 1
    return sprintf('%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x', @b);
}

sub now_ms { return int(time() * 1000) }

sub jencode { my ($v) = @_; return $JSON->encode($v // {}) }
sub jdecode {
    my ($s) = @_;
    return undef unless defined $s && length $s;
    my $v = eval { $JSON->decode($s) };
    return $@ ? undef : $v;
}

# Truncate from the head: keep first maxLines lines / maxBytes bytes.
# Returns ($content, %truncation).
sub truncate_head {
    my ($text, %o) = @_;
    my $max_lines = $o{max_lines} // 2000;
    my $max_bytes = $o{max_bytes} // (50 * 1024);
    my @lines = split /\n/, $text, -1;
    my $total = scalar @lines;
    if (@lines == 1 && length($lines[0]) > $max_bytes) {
        return ($lines[0], truncated => 1, first_line_exceeds_limit => 1,
                total_lines => $total, output_lines => 1, max_bytes => $max_bytes);
    }
    my @out;
    my $bytes = 0;
    my $truncated_by;
    for my $i (0 .. $#lines) {
        last if $i >= $max_lines;
        my $l = $lines[$i];
        my $lb = length($l) + ($i ? 1 : 0);
        if ($bytes + $lb > $max_bytes) { $truncated_by = 'bytes'; last }
        push @out, $l;
        $bytes += $lb;
    }
    my $cut = (@out < $total || defined $truncated_by);
    return (join("\n", @out),
            truncated => ($cut ? 1 : 0),
            truncated_by => $truncated_by // ($cut ? 'lines' : undef),
            total_lines => $total, output_lines => scalar(@out),
            max_lines => $max_lines, max_bytes => $max_bytes);
}

# Truncate from the tail: keep LAST maxLines lines / maxBytes bytes.
sub truncate_tail {
    my ($text, %o) = @_;
    my $max_lines = $o{max_lines} // 2000;
    my $max_bytes = $o{max_bytes} // (50 * 1024);
    my @lines = split /\n/, $text, -1;
    my $total = scalar @lines;
    # drop from front until within byte budget
    my $start = 0;
    my $bytes = length($text);
    while ($start < $#lines && $bytes > $max_bytes) {
        $bytes -= length($lines[$start]) + 1;
        $start++;
    }
    # then cap line count from the front of what remains
    if (($#lines - $start + 1) > $max_lines) {
        $start = $#lines - $max_lines + 1;
        $bytes = 0;
        for my $i ($start .. $#lines) { $bytes += length($lines[$i]) + 1 }
    }
    my @out = @lines[$start .. $#lines];
    return (join("\n", @out),
            truncated => ($start > 0 ? 1 : 0),
            total_lines => $total, output_lines => scalar(@out),
            start_line => $start + 1, max_bytes => $max_bytes);
}

sub format_size {
    my ($n) = @_;
    return "$n B" if $n < 1024;
    return sprintf('%.1f KB', $n / 1024) if $n < 1024 * 1024;
    return sprintf('%.1f MB', $n / (1024 * 1024));
}

# Rough token estimate: ~4 chars per token.
sub estimate_tokens { my ($text) = @_; return int(length($text // '') / 4) }

sub ensure_dir {
    my ($dir) = @_;
    return 1 if -d $dir;
    require File::Path;
    File::Path::make_path($dir);
    return 1;
}

1;
