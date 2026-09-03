# Install-time gates (docs/Wits.md §6): dependency pre-check with actionable
# messages, and the unit's t/*.t run from its source location before anything
# is copied.  A red test or missing dep aborts the install — nothing reaches
# the wits root untested.
use strict; use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::RealBin/../lib";
use File::Temp qw(tempdir);
use File::Path qw(make_path);

my $tmp = tempdir(CLEANUP => 1);
local $ENV{HOME}      = "$tmp/home";
local $ENV{CLAM_HOME} = "$tmp/clamhome";
delete $ENV{CLAM_WITS_PATH};
chdir $tmp or die "chdir: $!";

my $bin = "$FindBin::RealBin/../bin/clam";

sub write_file {
    my ($path, $content) = @_;
    (my $d = $path) =~ s{/[^/]+$}{};
    make_path($d);
    open my $fh, '>', $path or die "cannot write $path: $!";
    print {$fh} $content;
    close $fh;
}

sub deck_fixture {
    my ($dir, %o) = @_;
    (my $base = $dir) =~ s{.*/}{};
    my $ver = $o{version} // '0.1.0';
    write_file("$dir/deck.toml",
        "name=\"$base\"\nversion=\"$ver\"\nabout=\"fixture: $base\"\nusage=\"Test fixture.\"\n"
      . (defined $o{requires_bin} ? "requires_bin=[\"$o{requires_bin}\"]\n" : '')
      . "wits=[\"g.one\"]\n");
    write_file("$dir/g/one.wit", "name=one\ndescription=x\nsource = <<'PERL'\nreturn { ok => 1 };\nPERL\n");
}

# --- good: passing test, installs -------------------------------------------
deck_fixture("good");
write_file("good/t/01_ok.t", "#!/usr/bin/perl\nuse strict; use warnings;\nuse Test::More tests => 1;\nok(1, 'fine');\n");
my @out = `"$^X" "$bin" wits install "good" 2>&1`;
is($? >> 8, 0, "install with passing tests exits 0: " . join('', @out));
ok(-f "$ENV{CLAM_HOME}/wits/good/deck.toml", 'unit copied to CLAM_HOME/wits after green tests');

# --- plain: no t/ dir at all — installs without a test gate ------------------
deck_fixture("plain");
@out = `"$^X" "$bin" wits install "plain" 2>&1`;
is($? >> 8, 0, "unit without tests still installs: " . join('', @out));

# --- bad: failing test aborts the install ------------------------------------
deck_fixture("bad");
write_file("bad/t/01_fail.t", "#!/usr/bin/perl\nuse strict; use warnings;\nuse Test::More tests => 1;\nok(0, 'deliberately red');\n");
@out = `"$^X" "$bin" wits install "bad" 2>&1`;
isnt($? >> 8, 0, 'failing test aborts install');
like(join('', @out), qr/tests failed for bad \(01_fail\.t\)/, 'failure names the unit and file');
ok(!-d "$ENV{CLAM_HOME}/wits/bad", 'unit NOT copied when tests fail');

# --- depbin: missing binary refused with an actionable message ---------------
deck_fixture("depbin", requires_bin => "definitely-not-a-real-bin-clamtest15");
@out = `"$^X" "$bin" wits install "depbin" 2>&1`;
isnt($? >> 8, 0, 'missing binary aborts install');
like(join('', @out), qr/missing binary definitely-not-a-real-bin-clamtest15 \(fix: install/, 'actionable fix message');
ok(!-d "$ENV{CLAM_HOME}/wits/depbin", 'unit NOT copied when a dep is missing');

# --- manifest name must match directory basename (unit identity) -------------
write_file("mismatch/deck.toml", "name=\"other\"\nversion=\"0.1.0\"\nabout=\"x\"\nusage=\"y\"\nwits=[\"g.one\"]\n");
write_file("mismatch/g/one.wit", "name=one\ndescription=x\nsource = <<'PERL'\nreturn { ok => 1 };\nPERL\n");
@out = `"$^X" "$bin" wits install "mismatch" 2>&1`;
isnt($? >> 8, 0, 'manifest name != directory basename refused');
like(join('', @out), qr/does not match directory name/, 'identity mismatch named clearly');

# --- lockfile (docs/Wits.md §6) ----------------------------------------------
require Clam::WitLock;
my $lock = Clam::WitLock->load();
ok(exists $lock->{good}, 'install recorded a lock entry');
is($lock->{good}{version}, '0.1.0', 'lock records the version');
is($lock->{good}{tested}, 1, 'lock records that tests ran and passed');

# --- upgrade: higher version from a differently-located source ---------------
deck_fixture("$tmp/up/good", version => "0.2.0");
@out = `"$^X" "$bin" wits upgrade "$tmp/up/good" 2>&1`;
is($? >> 8, 0, "upgrade to higher version exits 0: " . join('', @out));
like(join('', @out), qr/upgraded 'good' v0\.1\.0 -> v0\.2\.0/, 'upgrade reports old -> new');
$lock = Clam::WitLock->load();
is($lock->{good}{version}, '0.2.0', 'lock updated after upgrade');

# --- downgrade refused without --force, allowed with it -----------------------
deck_fixture("$tmp/dn/good", version => "0.1.5");
@out = `"$^X" "$bin" wits upgrade "$tmp/dn/good" 2>&1`;
isnt($? >> 8, 0, 'downgrade refused without --force');
like(join('', @out), qr/refusing downgrade: installed v0\.2\.0 > new v0\.1\.5/, 'refusal names both versions');
$lock = Clam::WitLock->load();
is($lock->{good}{version}, '0.2.0', 'installed version untouched by refused downgrade');

@out = `"$^X" "$bin" wits upgrade "$tmp/dn/good" --force 2>&1`;
is($? >> 8, 0, "downgrade with --force exits 0: " . join('', @out));
$lock = Clam::WitLock->load();
is($lock->{good}{version}, '0.1.5', 'forced downgrade recorded');

# --- upgrade of a unit that was never installed --------------------------------
deck_fixture("$tmp/ghost/good2", version => "1.0.0");
@out = `"$^X" "$bin" wits upgrade "$tmp/ghost/good2" 2>&1`;
isnt($? >> 8, 0, 'upgrade of uninstalled unit fails');
like(join('', @out), qr/not installed: good2/, 'tells the user to install first');

# --- uninstall removes the lock entry ------------------------------------------
@out = `"$^X" "$bin" wits uninstall "good" 2>&1`;
is($? >> 8, 0, "uninstall exits 0: " . join('', @out));
$lock = Clam::WitLock->load();
ok(!exists $lock->{good}, 'lock entry removed on uninstall');

done_testing();
