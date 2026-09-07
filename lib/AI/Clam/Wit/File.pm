# AI::Clam::Wit::File — declarative wit files (.wit), ported from clam-old.
#
# A .wit file is TOML metadata with an embedded Perl source heredoc:
#
#   #!wit/toml
#   name="deduction_deduce"
#   type="rule"
#   enabled=true
#   triggers=[ "deduction.deduce", ]
#   [metadata]
#   category="deduction"
#   source = <<'PERL'
#   my ($self, $input, %ctx) = @_;
#   ...
#   PERL
#
# The handler contract (unchanged from clam-old): the compiled closure is
# called as  $code->($wit, $input, %ctx)  and returns a result hashref or
# undef ("did not fire").  $wit is a lightweight record with accessors.
package AI::Clam::Wit::File;
use strict;
use warnings;

our $VERSION = '1.0';

# ---------------------------------------------------------------------------
# parse_file($path) -> { meta => \%toml, source => $perl_source }
# Dies with a descriptive message on malformed files (caller records it).
# ---------------------------------------------------------------------------
sub parse_file {
    my ($class_or_self, $path) = @_;
    open my $fh, '<', $path or die "cannot read wit file $path: $!\n";
    my $content = do { local $/; <$fh> };
    close $fh;

    my @lines = split /\n/, $content;
    shift @lines if @lines && $lines[0] =~ /^#!wit\/\w+/m;

    # Split TOML metadata from the source heredoc (same algorithm as the
    # clam-old Loader: line-based, terminator must sit alone on its line).
    my (@toml_lines, $source);
    my ($in_heredoc, $heredoc_end) = (0, '');
    for my $line (@lines) {
        if (!$in_heredoc && $line =~ /^source\s*=\s*<<['"]?(\w+)['"]?\s*$/) {
            $heredoc_end = $1;
            $in_heredoc  = 1;
            next;
        }
        if ($in_heredoc) {
            if ($line =~ /^\Q$heredoc_end\E[ \t]*$/) {
                $in_heredoc = 0;
            } else {
                $source .= "$line\n";
            }
        } else {
            push @toml_lines, $line;
        }
    }
    die "wit file $path: unterminated source heredoc\n" if $in_heredoc;

    my $meta = parse_toml(join("\n", @toml_lines), path => $path);
    return { meta => $meta, source => ($source // '') };
}

# ---------------------------------------------------------------------------
# Minimal TOML parser for the .wit / deck.toml subset:
#   - bare keys; [table] and [[array-of-tables]] headers
#   - values: "basic strings" (with \n \t \\ \" escapes), 'literal strings',
#     multi-line """...""" / '''...''' strings, integers, floats, booleans,
#     arrays of scalars (single or multi-line), bare words (kept as strings)
#   - comments (# ...) and blank lines
# Not a general TOML implementation — enough for every file in the decks.
# ---------------------------------------------------------------------------
sub parse_toml {
    # Accepts both function and method call syntax: a leading package name is
    # dropped (the only realistic TOML text starting with it would be nonsense).
    my @a = @_;
    shift @a if @a && !ref $a[0] && $a[0] =~ /^AI::Clam::Wit::File\b/;
    my ($text, %opts) = @a;
    my $where = $opts{path} // 'toml';
    my (%data, $table);
    $table = \%data;

    my @lines = split /\n/, $text;
    my $i = 0;
    while ($i < @lines) {
        my $line = $lines[$i];
        $i++;
        next if $line =~ /^\s*(?:#|$)/;

        if ($line =~ /^\[\[\s*([\w.-]+)\s*\]\]/) {          # [[array of tables]]
            push @{ $data{$1} //= [] }, {};
            $table = $data{$1}[-1];
            next;
        }
        if ($line =~ /^\[\s*([\w.-]+)\s*\]\s*(?:#.*)?$/) {  # [table]
            $table = $data{$1} //= {};
            next;
        }

        # key = value  (value may continue over following lines)
        my ($key, $val);
        if ($line =~ /^([\w.-]+)\s*=\s*(.*)$/s) {
            ($key, $val) = ($1, $2);
        } else {
            die "$where: cannot parse line: $line\n";
        }

        # Multi-line strings: """ ... """ or ''' ... '''.  TOML trims one
        # newline directly after the opening delimiter.
        if ($val =~ m{^("""|''')(.*)\Z}s) {
            my ($delim, $rest_of_line) = ($1, $2);
            my @raw = ("$delim$rest_of_line");
            while (!(_mline_closed(join("\n", @raw), $delim)) && $i < @lines) {
                push @raw, $lines[$i];
                $i++;
            }
            my $full = join("\n", @raw);
            die "$where: unterminated multi-line string for key '$key'\n"
                unless _mline_closed($full, $delim);
            $full =~ s/^\Q$delim\E//;
            $full =~ s/\Q$delim\E[ \t]*(?:#.*)?\s*\Z// or die "$where: unterminated multi-line string for key '$key'\n";
            $full =~ s/^\n//;
            if ($delim eq '"""') {
                $table->{$key} = _unesc_basic($full);
            } else {
                $full =~ s/''/'/g;
                $table->{$key} = $full;
            }
            next;
        }

        # Plain arrays may span lines: keep consuming while [ is unbalanced.
        my $rest = $val;
        while (_brackets_open($rest) && $i < @lines) {
            $rest .= "\n" . $lines[$i];
            $i++;
        }
        $table->{$key} = _parse_value($rest, $where);
    }
    return \%data;
}

# True if the text contains an unclosed [ (outside quotes) — i.e. a plain
# array value continues on the next line.
sub _brackets_open {
    my ($t) = @_;
    my ($depth, $in_q, $esc) = (0, undef, 0);
    for my $ch (split //, $t) {
        if ($in_q) {
            if ($esc) { $esc = 0; }
            elsif ($ch eq '\\' && $in_q eq '"') { $esc = 1; }
            elsif ($ch eq $in_q) { $in_q = undef; }
        }
        elsif ($ch eq '"' || $ch eq "'") { $in_q = $ch; }
        elsif ($ch eq '[') { $depth++; }
        elsif ($ch eq ']') { $depth--; }
    }
    return $depth > 0;
}

# True if a multi-line string value (INCLUDING the opening delimiter at pos 0)
# contains its closing delimiter.
sub _mline_closed {
    my ($full, $delim) = @_;
    return 0 unless index($full, $delim) == 0;
    my $len = length $delim;
    my $i   = $len;
    while ($i <= length($full) - $len) {
        if (substr($full, $i, $len) eq $delim) {
            if ($delim eq '"""') {
                # odd run of backslashes directly before => escaped quote
                my $bs = 0;
                for (my $j = $i - 1; $j >= 0 && substr($full, $j, 1) eq '\\'; $j--) { $bs++; }
                return 1 if $bs % 2 == 0;
            } else {
                return 1;   # literal: three consecutive quotes always close
            }
        }
        $i++;
    }
    return 0;
}

sub _unesc_basic {
    my ($s) = @_;
    $s =~ s/\\n/\n/g; $s =~ s/\\t/\t/g;
    $s =~ s/\\\r/\r/g; $s =~ s/\\"/"/g; $s =~ s/\\\\/\\/g;
    return $s;
}

sub _parse_value {
    my ($v, $where) = @_;
    $v =~ s/^\s+|\s+$//g;

    if ($v =~ /^\[(.*)\]$/s) {         # array (items parsed individually so a
        my $inner = $1;                # '#' inside one string can't eat the rest)
        return [] unless length $inner;
        my @items;
        for my $part (_split_array_items($inner)) {
            push @items, _parse_value($part, $where);
        }
        return \@items;
    }
    # Trailing comment: only strip for unquoted values (strings may contain '#').
    $v =~ s/\s+#.*$// unless $v =~ /^["']/;
    if ($v =~ /^"((?:[^"\\]|\\.)*)"$/s) {   # basic string with escapes
        my $s = $1;
        $s =~ s/\\n/\n/g; $s =~ s/\\t/\t/g;
        $s =~ s/\\\r/\r/g; $s =~ s/\\"/"/g; $s =~ s/\\\\/\\/g;
        return $s;
    }
    if ($v =~ /^'((?:[^']|'')*)'$/s) {     # literal string ('' = escaped quote)
        my $s = $1;
        $s =~ s/''/'/g;
        return $s;
    }
    return 1   if $v eq 'true';
    return 0   if $v eq 'false';
    return 0 + $v if $v =~ /^[+-]?\d+$/;
    return 0 + $v if $v =~ /^[+-]?(?:\d+\.\d*|\.\d+)$/;
    return $v;                            # bare word -> string
}

# Split array items on commas that are not inside quotes (backslash escapes
# honoured in basic strings).
sub _split_array_items {
    my ($inner) = @_;
    my (@items, $cur, $in_q, $esc);
    for my $ch (split //, $inner) {
        if ($in_q) {
            $cur .= $ch;
            if ($esc)                 { $esc = 0; }
            elsif ($ch eq '\\' && $in_q eq '"') { $esc = 1; }
            elsif ($ch eq $in_q)      { $in_q = undef; }
        }
        elsif ($ch eq '"' || $ch eq "'") { $in_q = $ch; $cur .= $ch; }
        elsif ($ch eq ',') {
            my $t = trim($cur);
            push @items, $t if length $t && $t !~ /^#/;   # skip comment-only fragments
            $cur = '';
        }
        else { $cur .= $ch; }
    }
    my $t = trim($cur);
    push @items, $t if length $t && $t !~ /^#/;
    return @items;
}

sub trim { my ($s) = @_; $s =~ s/^\s+|\s+$//g; return $s; }

# ---------------------------------------------------------------------------
# AI::Clam::Wit::File::Record — the lightweight $self passed to handlers.
# Field accessors over the parsed metadata (name, type, version, description,
# usage, priority, stateful, enabled, timeout, metadata, ...).  Unknown
# fields return undef rather than dying (ported wits probe optional fields).
# ---------------------------------------------------------------------------
package AI::Clam::Wit::File::Record;

sub AUTOLOAD {
    our $AUTOLOAD;
    my ($self) = @_;
    (my $field = $AUTOLOAD) =~ s/.*://;
    return if $field eq 'DESTROY';
    return undef unless exists $self->{$field};
    return $self->{$field};
}

package AI::Clam::Wit::File;

# ---------------------------------------------------------------------------
# compile($source, %o) -> coderef
# Same compilation as clam-old: the source is the body of a closure that
# receives ($self, $input, %ctx).  JSON::PP is made available inside.
# ---------------------------------------------------------------------------
sub compile {
    my ($class_or_self, $source, %opts) = @_;
    my $name = $opts{name} // 'anonymous';
    my $code;
    my @warnings;
    {
        local $SIG{__WARN__} = sub { push @warnings, $_[0] };
        $code = eval "use JSON::PP; sub { $source }";
    }
    die "wit '$name' failed to compile: $@" if $@;
    warn "[wits] warnings compiling '$name':\n  " . join("\n  ", @warnings) . "\n"
        if @warnings && $ENV{CLAM_DEBUG};
    return $code;
}

1;
