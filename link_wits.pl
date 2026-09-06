#!/usr/bin/env perl
use strict;
use warnings;
use File::Spec;
use File::Basename;
use Cwd;
use Getopt::Long;

my $CLEAN = 0;
GetOptions('clean' => \$CLEAN) or usage();

my $ROOT = find_root();
my $WITS_DIR = "$ROOT/wits";
my $LIB_WITS = "$ROOT/lib/Clam/Wits";

die "Cannot find wits/ directory at $WITS_DIR\n" unless -d $WITS_DIR;

if ($CLEAN) {
    clean_symlinks();
} else {
    create_symlinks();
}

exit 0;

sub find_root {
    my $dir = dirname($0);
    chdir($dir) if $dir ne '.';
    my $cwd = getcwd();
    die "Not in a clam checkout (no wits/ directory)\n" unless -d "$cwd/wits";
    return $cwd;
}

sub relative_path {
    my ($from, $to) = @_;
    my $rel = File::Spec->abs2rel($to, dirname($from));
    return File::Spec->catfile(split m{/}, $rel);
}

sub create_symlinks {
    mkdir $LIB_WITS unless -d $LIB_WITS;

    my @wits = glob("$WITS_DIR/*");
    my ($created, $skipped, $failed) = (0, 0, 0);

    for my $wit_dir (@wits) {
        next unless -d $wit_dir;
        my $name = basename($wit_dir);

        my $ns_dir = "$wit_dir/lib/Clam/Wits";
        next unless -d $ns_dir;

        my @ns_entries = glob("$ns_dir/*");
        for my $ns_entry (@ns_entries) {
            my $ns_name = basename($ns_entry);
            my $target = "$LIB_WITS/$ns_name";
            my $rel = relative_path($target, $ns_entry);

            if (-l $target) {
                my $link_target = readlink($target);
                if ($link_target eq $rel) {
                    $skipped++;
                    next;
                }
                unlink $target or do {
                    warn "Cannot remove old symlink $target: $!\n";
                    $failed++;
                    next;
                };
            } elsif (-e $target) {
                warn "Skipping $target — exists and is not a symlink\n";
                $failed++;
                next;
            }

            symlink($rel, $target) or do {
                warn "Cannot create symlink $target -> $rel: $!\n";
                $failed++;
                next;
            };
            $created++;
        }
    }

    print "Created: $created symlinks\n";
    print "Skipped: $skipped (already correct)\n";
    print "Failed:  $failed\n" if $failed;
}

sub clean_symlinks {
    return unless -d $LIB_WITS;

    my $removed = 0;
    my @entries = glob("$LIB_WITS/*");
    for my $entry (@entries) {
        next unless -l $entry;
        unlink $entry or do {
            warn "Cannot remove $entry: $!\n";
            next;
        };
        $removed++;
    }

    # Remove empty parent dir if no real files remain
    if (-d $LIB_WITS) {
        my @remaining = glob("$LIB_WITS/*");
        rmdir $LIB_WITS unless @remaining;
    }

    print "Removed: $removed symlinks\n";
}

sub usage {
    print STDERR <<'EOF';
Usage: $0 [OPTIONS]

Create relative symlinks from lib/Clam/Wits/* to wits/*/lib/Clam/Wits/*.

This makes the dev tree behave like an installed CPAN tree, so tests
and IDEs can find all wit modules from a single @INC path.

Options:
  --clean    Remove all symlinks instead of creating them
  -h, --help Show this help

Examples:
  perl link_wits.pl              # create symlinks
  perl link_wits.pl --clean      # remove symlinks

EOF
    exit 1;
}
