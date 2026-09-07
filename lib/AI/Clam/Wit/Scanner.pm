# AI::Clam::Wit::Scanner — discovers installed wits via grep for # CLAM-WIT: markers.
# Populates the SQLite DB with wit metadata. One-time scan, then DB is the cache.
package AI::Clam::Wit::Scanner;
use strict;
use warnings;

# Scan @INC (or explicit dirs) for Clam/Wit/*.pm files with # CLAM-WIT: markers.
# Returns an arrayref of wit metadata hashes.
sub scan {
    my ($class, %o) = @_;
    my @dirs = @{ $o{dirs} // [] };
    @dirs = _default_dirs() unless @dirs;

    my @wits;
    for my $dir (@dirs) {
        next unless -d "$dir/Clam/Wits";
        opendir(my $dh, "$dir/Clam/Wits") or next;
        for my $file (grep { /\.pm$/ && -f "$dir/Clam/Wits/$_" } readdir($dh)) {
            my $path = "$dir/Clam/Wits/$file";
            my $meta = $class->parse_marker($path);
            next unless $meta;
            push @wits, $meta;
        }
        closedir $dh;
    }
    return \@wits;
}

# Parse the # CLAM-WIT: comment block from a .pm file.
# Returns a hashref with metadata, or undef if no marker found.
sub parse_marker {
    my ($class, $path) = @_;
    open my $fh, '<', $path or return undef;

    my $meta = {};
    my $found = 0;
    while (my $line = <$fh>) {
        last if $line =~ /^package\s/;   # stop at package declaration
        if ($line =~ /^#\s*CLAM-WIT:\s*(.+)$/) {
            my $kv = $1;
            if ($kv =~ /^(\w+)=(.*)$/) {
                my ($key, $val) = ($1, $2);
                $val =~ s/\s+$//;
                $meta->{$key} = $val;
                $found = 1;
            }
        }
    }
    close $fh;

    return undef unless $found;

    # Default name from filename
    (my $file = $path) =~ s{.*/}{};
    $file =~ s{\.pm$}{};
    $meta->{name} //= $file;
    $meta->{version} //= '0.0.1';
    $meta->{_path} = $path;

    return $meta;
}

# Default @INC directories that might contain Clam/Wit/*.pm
sub _default_dirs {
    require Config;
    return grep { -d "$_/Clam/Wits" } @INC;
}

# Register scanned wits in the SQLite DB.
# $store is a AI::Clam::Store object. $wits is arrayref from scan().
# Returns (inserted, updated) counts.
sub register_in_db {
    my ($class, $store, $wits) = @_;
    my ($inserted, $updated) = (0, 0);

    for my $meta (@$wits) {
        my $existing = eval { $store->wit_get($meta->{name}) };
        if ($existing) {
            $store->wit_update(
                name    => $meta->{name},
                version => $meta->{version},
                about   => $meta->{about},
                usage   => $meta->{usage},
                hint    => $meta->{hint},
                path    => $meta->{_path},
            );
            $updated++;
        } else {
            $store->wit_insert(
                name    => $meta->{name},
                version => $meta->{version},
                about   => $meta->{about},
                usage   => $meta->{usage},
                hint    => $meta->{hint},
                author  => $meta->{author},
                license => $meta->{license},
                path    => $meta->{_path},
                state   => 'available',
            );
            $inserted++;
        }
    }
    return ($inserted, $updated);
}

1;
