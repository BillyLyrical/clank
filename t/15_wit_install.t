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
    write_file("$dir/deck.toml",
        "name=\"$dir\"\nversion=\"0.1.0\"\nabout=\"fixture: $dir\"\nusage=\"Test fixture.\"\n"
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

done_testing();
