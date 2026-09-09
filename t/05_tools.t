use strict; use warnings;
use Test::More;
use lib 'lib';
use File::Temp qw(tempdir);
use Clank::Tools::Read;
use Clank::Tools::Write;
use Clank::Tools::Edit;
use Clank::Tools::Bash;

my $dir = tempdir(CLEANUP => 1);
chdir $dir or die "chdir: $!";

# --- write ---
my $w = Clank::Tools::Write->new;
my $r = $w->run({ path => 'sub/dir/hello.txt', content => "line1\nline2\n" });
is($r->{isError}, 0, 'write ok');
ok(-f 'sub/dir/hello.txt', 'parent dirs created + file exists');

# --- read ---
my $rd = Clank::Tools::Read->new;
$r = $rd->run({ path => 'sub/dir/hello.txt' });
is($r->{output}, "line1\nline2", 'read full small file');
$r = $rd->run({ path => 'missing.txt' });
ok($r->{isError} && $r->{output} =~ /no such file/, 'read missing -> error');

# read offset/limit + truncation note
my $bigfile = "big.txt";
open my $fh, '>', $bigfile or die;
print {$fh} "$_\n" for 1 .. 3000;
close $fh;
$r = $rd->run({ path => $bigfile });
like($r->{output}, qr/truncated: showing lines 1-2000 of 3000/, 'read truncates at 2000 lines');
$r = $rd->run({ path => $bigfile, offset => 5, limit => 3 });
is($r->{output}, "5\n6\n7", 'read offset+limit');

# --- edit ---
my $ed = Clank::Tools::Edit->new;
open $fh, '>', 'editme.txt' or die; print {$fh} "alpha\nbeta\ngamma\n"; close $fh;

$r = $ed->run({ path => 'editme.txt', edits => [ { oldText => 'beta', newText => 'BETA' } ] });
is($r->{isError}, 0, 'simple edit ok');
open $fh, '<', 'editme.txt'; my $c = do { local $/; <$fh> }; close $fh;
is($c, "alpha\nBETA\ngamma\n", 'edit applied');

# multiple disjoint edits in one call (matched against ORIGINAL)
open $fh, '>', 'multi.txt' or die; print {$fh} "one two three four\n"; close $fh;
$r = $ed->run({ path => 'multi.txt', edits => [
    { oldText => 'one',  newText => 'ONE' },
    { oldText => 'four', newText => 'FOUR' },
] });
is($r->{isError}, 0, 'multi edit ok');
open $fh, '<', 'multi.txt'; $c = do { local $/; <$fh> }; close $fh;
is($c, "ONE two three FOUR\n", 'both edits applied');

# non-unique oldText rejected
$r = $ed->run({ path => 'multi.txt', edits => [ { oldText => 'two', newText => 'x' } ] });
ok(!$r->{isError}, 'unique match ok');
open $fh, '>', 'dup.txt' or die; print {$fh} "same same\n"; close $fh;
$r = $ed->run({ path => 'dup.txt', edits => [ { oldText => 'same', newText => 'x' } ] });
ok($r->{isError} && $r->{output} =~ /not unique/, 'non-unique rejected');

# overlapping edits rejected
open $fh, '>', 'ovl.txt' or die; print {$fh} "abcdef\n"; close $fh;
$r = $ed->run({ path => 'ovl.txt', edits => [
    { oldText => 'abc', newText => 'X' },
    { oldText => 'cde', newText => 'Y' },
] });
ok($r->{isError} && $r->{output} =~ /overlap/i, 'overlapping edits rejected');

# --- bash ---
my $b = Clank::Tools::Bash->new;
$r = $b->run({ command => 'echo hello-bash' });
like($r->{output}, qr/hello-bash/, 'bash stdout captured');
like($r->{output}, qr/exit code: 0/, 'exit code reported');

$r = $b->run({ command => 'echo err >&2; exit 3' });
like($r->{output}, qr/stderr:\nerr/, 'stderr captured');
like($r->{output}, qr/exit code: 3/, 'nonzero exit reported');

# tail truncation + temp file spill
$r = $b->run({ command => 'seq 1 5000' });
like($r->{output}, qr/truncated to last 2000 lines/, 'bash output tail-truncated');
like($r->{output}, qr/full output: (\S+)/, 'spill file mentioned');
my ($spill) = $r->{output} =~ /full output: (\S+)/;
ok(-f $spill && -s $spill > 10000, 'spill file has full output');

# timeout kills the process group
$r = $b->run({ command => 'sleep 5', timeout => 1 });
ok($r->{isError} && $r->{output} =~ /timed out/, 'timeout enforced');

done_testing();
