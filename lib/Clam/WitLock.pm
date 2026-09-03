# Install lockfile (docs/Wits.md §6): <clam home>/wits.lock.json maps unit name
# -> {name, version, source, installed_at, tested}.  The record is written when
# a unit passes the install gates and lands in the wits root; `wits upgrade`
# compares against it to refuse downgrades without --force.
package Clam::WitLock;
use strict;
use warnings;

sub path {
    require Clam::Util;
    return Clam::Util::clam_home() . '/wits.lock.json';
}

# Read the lockfile as a hashref (empty when absent or corrupt — a broken
# lockfile must not wedge install/uninstall).
sub load {
    my ($class) = @_;
    my $p = path();
    return {} unless -f $p;
    open my $fh, '<', $p or return {};
    local $/;
    my $raw = <$fh>;
    close $fh;
    require JSON::PP;
    my $data = eval { JSON::PP->new->decode($raw) };
    return (ref $data eq 'HASH') ? $data : {};
}

# Atomic save: write to a temp file in the same directory, then rename over.
sub save {
    my ($class, $lock) = @_;
    require Clam::Util;
    require JSON::PP;
    my $p = path();
    (my $parent = $p) =~ s{/[^/]+$}{};
    Clam::Util::ensure_dir($parent) if length $parent;
    my $json = JSON::PP->new->canonical(1)->pretty(1)->encode($lock);
    my $tmp  = "$p.tmp.$$";
    open my $fh, '>', $tmp or die "cannot write lockfile tmp: $!\n";
    print {$fh} $json;
    close $fh or die "close lockfile tmp: $!\n";
    rename $tmp, $p or do { unlink $tmp; die "rename lockfile: $!\n" };
    return 1;
}

# Record (or replace) one unit's entry.  Extra keys are stored verbatim.
sub record {
    my ($class, %e) = @_;
    die "WitLock->record: name required\n" unless length($e{name} // '');
    $e{installed_at} //= time;
    my $lock = __PACKAGE__->load();
    $lock->{ $e{name} } = {
        name         => $e{name},
        version      => $e{version} // '',
        source       => $e{source}  // '',
        installed_at => $e{installed_at},
        tested       => $e{tested} ? 1 : 0,
    };
    __PACKAGE__->save($lock);
    return $lock->{ $e{name} };
}

sub remove {
    my ($class, $name) = @_;
    my $lock = __PACKAGE__->load();
    return 0 unless exists $lock->{$name};
    delete $lock->{$name};
    save($lock);
    return 1;
}

# Dot-separated version compare: -1 / 0 / 1.  Missing components count as 0,
# so "1.0" eq "1.0.0"; non-numeric tails are ignored ("1.2-beta" ~ "1.2").
sub ver_cmp {
    my ($class, $a, $b) = @_;
    my @pa = grep { /^\d+$/ } split /\./, "$a";
    my @pb = grep { /^\d+$/ } split /\./, "$b";
    for my $i (0 .. (($#pa > $#pb) ? $#pa : $#pb)) {
        my $c = (($pa[$i] // 0) <=> ($pb[$i] // 0));
        return $c if $c;
    }
    return 0;
}

1;
