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
my $LIB_WITS = "$ROOT/lib/Clank/Wits";

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
    die "Not in a clank checkout (no wits/ directory)\n" unless -d "$cwd/wits";
    return $cwd;
}

sub create_symlinks {
    mkdir $LIB_WITS unless -d $LIB_WITS;

    my ($created, $skipped, $failed) = (0, 0, 0);

    for my $wit_dir (glob("$WITS_DIR/*")) {
        next unless -d $wit_dir;
        my $ns_dir = "$wit_dir/lib/Clank/Wits";
        next unless -d $ns_dir;

        opendir(my $dh, $ns_dir) or next;
        for my $entry (sort readdir $dh) {
            next if $entry =~ /^\./;
            my $source = "$ns_dir/$entry";
            next unless -d $source;
            my $target = "$LIB_WITS/$entry";

            if (-l $target) {
                my $link_target = readlink($target);
                my $rel = File::Spec->abs2rel($source, $LIB_WITS);
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

            my $rel = File::Spec->abs2rel($source, $LIB_WITS);
            symlink($rel, $target) or do {
                warn "Cannot create symlink $target -> $rel: $!\n";
                $failed++;
                next;
            };
            $created++;
        }
        closedir $dh;
    }

    print "Created: $created symlinks\n";
    print "Skipped: $skipped (already correct)\n";
    print "Failed:  $failed\n" if $failed;
}

sub clean_symlinks {
    return unless -d $LIB_WITS;

    my $removed = 0;
    opendir(my $dh, $LIB_WITS) or return;
    for my $entry (readdir $dh) {
        next if $entry =~ /^\./;
        my $path = "$LIB_WITS/$entry";
        next unless -l $path;
        unlink $path or do {
            warn "Cannot remove $path: $!\n";
            next;
        };
        $removed++;
    }
    closedir $dh;

    rmdir $LIB_WITS unless glob("$LIB_WITS/*");

    print "Removed: $removed symlinks\n";
}

sub usage {
    print STDERR <<'EOF';
Usage: $0 [OPTIONS]

Create relative symlinks from lib/Clank/Wits/* to wits/*/lib/Clank/Wits/*.

This makes the dev tree behave like an installed CPAN tree, so tests
and code can find all wit modules from a single @INC path.

Options:
  --clean    Remove all symlinks instead of creating them
  -h, --help Show this help

Examples:
  perl link_wits.pl              # create symlinks
  perl link_wits.pl --clean      # remove symlinks

EOF
    exit 1;
}
