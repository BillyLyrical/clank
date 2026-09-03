# Clam::WitIndex — discoverability index for installed wits (docs/Wits.md §3).
#
# One JSON file at $CLAM_HOME/wits.index.json mapping unit name -> {about,
# usage, version, dir}.  The manifests are truth; this is a cache kept fresh by
# the `clam wits` commands so humans can grep it and later tooling (FTS5) can
# index it.  Only installed units are indexed (user + project roots); ephemeral
# roots (CLAM_WITS_PATH, -w) are per-invocation and never indexed.
package Clam::WitIndex;
use strict;
use warnings;
use JSON::PP ();

sub home {
    require Clam::Util;
    return Clam::Util::clam_home();
}

sub path { home() . '/wits.index.json' }

# Installed roots that exist: project (.clam/wits) and user (~/.clam/wits).
sub roots {
    my %seen;
    return grep { ! $seen{$_}++ && -d $_ } ('.clam/wits', home() . '/wits');
}

# Parse a unit's manifest (deck.toml or wit.toml) into an index entry, or
# undef when the dir has no manifest.  Manifest fields win over everything;
# name falls back to the directory basename.
sub scan_dir {
    my ($class, $dir) = @_;
    for my $mf (qw(deck.toml wit.toml)) {
        next unless -f "$dir/$mf";
        require Clam::Wit::File;
        open my $fh, '<', "$dir/$mf" or return undef;
        my $content = do { local $/; <$fh> };
        close $fh;
        my $meta = eval { Clam::Wit::File::parse_toml($content) };
        if ($@) {
            warn "[wits] unparseable manifest $dir/$mf: $@";
            return undef;
        }
        (my $name = $dir) =~ s{.*/}{};
        return {
            name    => $meta->{name} // $name,
            about   => $meta->{about}   // '(undocumented)',
            usage   => $meta->{usage}   // '',
            version => $meta->{version} // '0',
            dir     => $dir,
        };
    }
    return undef;
}

# Rebuild the index from disk: every subdir of an installed root that carries
# a manifest becomes one entry (the root itself too, if it is a unit).  Writes
# the file atomically and returns the index hashref.
sub rebuild {
    my ($class) = @_;
    my %idx;
    for my $root (roots()) {
        my $self_entry = __PACKAGE__->scan_dir($root);
        $idx{ $self_entry->{name} } = $self_entry if $self_entry;
        opendir(my $dh, $root) or next;
        for my $e (sort grep { !/^\./ && -d "$root/$_" } readdir($dh)) {
            my $entry = __PACKAGE__->scan_dir("$root/$e");
            $idx{ $entry->{name} } = $entry if $entry;
        }
        closedir $dh;
    }
    __PACKAGE__->save(\%idx);
    return \%idx;
}

sub read {
    my ($class) = @_;
    my $p = path();
    open my $fh, '<', $p or return {};
    my $content = do { local $/; <$fh> };
    close $fh;
    my $idx = eval { JSON::PP->new->decode($content) };
    if ($@ || ref $idx ne 'HASH') {
        warn "[wits] corrupt index at $p, ignoring: $@" if length "$content";
        return {};
    }
    return $idx;
}

# Named save() rather than write(): the bareword would shadow Perl's built-in
# formatted-output `write` and confuse both the parser and future readers.
sub save {
    my ($class, $idx) = @_;
    require Clam::Util;
    my $p = path();
    (my $parent = $p) =~ s{/[^/]+$}{};
    Clam::Util::ensure_dir($parent) if length $parent;
    my $json = JSON::PP->new->canonical(1)->pretty(1)->encode($idx);
    my $tmp  = "$p.tmp.$$";
    open my $out, '>', $tmp or die "cannot write $tmp: $!\n";
    print {$out} $json;
    close $out or die "close $tmp: $!\n";
    rename $tmp, $p or die "rename $tmp -> $p: $!\n";
    return 1;
}

1;
