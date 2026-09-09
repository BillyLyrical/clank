#!/usr/bin/env perl
# t/16_scanner.t — test # CLANK-WIT: marker parsing and wit registry DB
use strict;
use warnings;
use Test::More;
use FindBin;

use lib "$FindBin::RealBin/../lib";
use Clank::Store;
use Clank::Wit::Scanner;

# --- parse_marker tests ----------------------------------------------------

# Create a temp .pm file with CLANK-WIT markers
use File::Temp qw(tempfile);
my ($fh, $tmpfile) = tempfile(SUFFIX => '.pm', UNLINK => 1);
print $fh <<'EOF';
# CLANK-WIT: name=TestWit
# CLANK-WIT: version=0.5.0
# CLANK-WIT: about=A test wit for scanner tests
# CLANK-WIT: usage=Load during tests only
# CLANK-WIT: hint=testing scanner parsing
# CLANK-WIT: author=tester
# CLANK-WIT: license=MIT
package Clank::Wits::TestWit;
use strict;
use warnings;
sub register { }
1;
EOF
close $fh;

my $meta = Clank::Wit::Scanner->parse_marker($tmpfile);
ok($meta, 'parse_marker returns metadata');
is($meta->{name}, 'TestWit', 'name parsed');
is($meta->{version}, '0.5.0', 'version parsed');
is($meta->{about}, 'A test wit for scanner tests', 'about parsed');
is($meta->{usage}, 'Load during tests only', 'usage parsed');
is($meta->{hint}, 'testing scanner parsing', 'hint parsed');
is($meta->{author}, 'tester', 'author parsed');
is($meta->{license}, 'MIT', 'license parsed');
is($meta->{_path}, $tmpfile, '_path set');

# File without CLANK-WIT marker
my ($fh2, $tmpfile2) = tempfile(SUFFIX => '.pm', UNLINK => 1);
print $fh2 <<'EOF';
# Just a regular module
package Foo;
use strict;
1;
EOF
close $fh2;

my $no_meta = Clank::Wit::Scanner->parse_marker($tmpfile2);
ok(!$no_meta, 'parse_marker returns undef for files without marker');

# --- scan tests -----------------------------------------------------------

# Create a mock @INC dir with Clank/Wit/*.pm
use File::Temp qw(tempdir);
my $tmpdir = tempdir(CLEANUP => 1);
my $wit_dir = "$tmpdir/Clank/Wits";
File::Path::make_path($wit_dir);

# Copy our test file there
use File::Copy;
copy($tmpfile, "$wit_dir/TestWit.pm") or die "copy: $!";

my $wits = Clank::Wit::Scanner->scan(dirs => [$tmpdir]);
is(scalar @$wits, 1, 'scan finds one wit');
is($wits->[0]{name}, 'TestWit', 'scan finds correct wit name');
is($wits->[0]{about}, 'A test wit for scanner tests', 'scan preserves about');

# --- DB registration tests ------------------------------------------------

my $store = Clank::Store->new(path => ':memory:');
my ($ins, $upd) = Clank::Wit::Scanner->register_in_db($store, $wits);
is($ins, 1, 'register_in_db inserts one wit');
is($upd, 0, 'register_in_db: no updates on first insert');

my $stored = $store->wit_get('TestWit');
ok($stored, 'wit_get returns stored wit');
is($stored->{name}, 'TestWit', 'stored name matches');
is($stored->{about}, 'A test wit for scanner tests', 'stored about matches');
is($stored->{state}, 'available', 'initial state is available');

# Update the same wit
$wits->[0]{about} = 'Updated description';
($ins, $upd) = Clank::Wit::Scanner->register_in_db($store, $wits);
is($ins, 0, 'register_in_db: no inserts on update');
is($upd, 1, 'register_in_db: one update');

$stored = $store->wit_get('TestWit');
is($stored->{about}, 'Updated description', 'about updated in DB');

# wit_list
my @all = @{ $store->wit_list };
is(scalar @all, 1, 'wit_list returns one wit');
is($all[0]{name}, 'TestWit', 'wit_list has correct name');

# wit_set_state
$store->wit_set_state('TestWit', 'active');
$stored = $store->wit_get('TestWit');
is($stored->{state}, 'active', 'wit_set_state changes state to active');
ok(defined $stored->{loaded_at}, 'loaded_at set when active');

$store->wit_set_state('TestWit', 'disabled');
$stored = $store->wit_get('TestWit');
is($stored->{state}, 'disabled', 'wit_set_state changes state to disabled');
ok(!defined $stored->{loaded_at}, 'loaded_at cleared when disabled');

# wit_remove
$store->wit_remove('TestWit');
ok(!$store->wit_get('TestWit'), 'wit_remove deletes wit');

done_testing;
