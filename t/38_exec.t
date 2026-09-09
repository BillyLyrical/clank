use strict; use warnings;
use Test::More;
use lib 'lib';
use File::Temp qw(tempdir);
use Clank::Exec qw(exec_cmd);

my $dir = tempdir(CLEANUP => 1);
chdir $dir or die "chdir: $!";

# basic command
my $r = exec_cmd(command => 'echo hello');
is($r->{stdout}, "hello\n", 'exec_cmd stdout captured');
is($r->{exit_code}, 0, 'exit code 0');
is($r->{timed_out}, 0, 'not timed out');

# stderr
$r = exec_cmd(command => 'echo err >&2');
is($r->{stderr}, "err\n", 'exec_cmd stderr captured');

# nonzero exit
$r = exec_cmd(command => 'exit 3');
is($r->{exit_code}, 3, 'nonzero exit code');

# arrayref command
$r = exec_cmd(command => ['perl', '-e', 'print "perl-ok"']);
is($r->{stdout}, 'perl-ok', 'arrayref command works');

# timeout
$r = exec_cmd(command => 'sleep 5', timeout => 1);
is($r->{timed_out}, 1, 'timeout detected');
is($r->{exit_code}, -1, 'exit code -1 on timeout');

# invalid command
$r = exec_cmd(command => 'nonexistent_command_xyz_12345');
is($r->{exit_code} != 0, 1, 'bad command nonzero exit');

done_testing();
