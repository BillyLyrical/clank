use strict; use warnings;
use Test::More;
use lib 'lib';
use File::Temp qw(tempdir);
use File::Path;

# Test Bands: composable societies of wits via bus workflows.

use Clank::Store;
use Clank::Bus;
use Clank::Band;

# --- setup: in-memory store + bus ---

my $store = Clank::Store->new(db => ':memory:');
my $bus = Clank::Bus->new(store => $store, sender => 'test');
my $band_mod = Clank::Band->new(bus => $bus, store => $store);

# --- test 1: discover bands from directory ---

my $dir = tempdir(CLEANUP => 1);
File::Path::make_path("$dir/my-band");
open my $fh, '>', "$dir/my-band/band.toml" or die;
print $fh <<'EOF';
name = "my-test-band"
description = "A test band"
trigger = "band.my-test"
output = "band.my-test.done"

[[steps]]
name = "step1"
code = "return { step1_done => 1 };"
EOF
close $fh;

my @bands = Clank::Band::discover(extra => [$dir]);
my ($my_band) = grep { $_->{name} eq 'my-test-band' } @bands;
ok($my_band, 'discovered my-test-band');
is($my_band->{trigger}, 'band.my-test', 'band trigger correct');
is(scalar @{$my_band->{steps}}, 1, 'band has 1 step');
is($my_band->{steps}[0]{name}, 'step1', 'step name correct');
is($my_band->{steps}[0]{code}, 'return { step1_done => 1 };', 'step code correct');

# --- test 2: parse band with multiple steps ---

File::Path::make_path("$dir/multi-step");
open $fh, '>', "$dir/multi-step/band.toml" or die;
print $fh <<'EOF';
name = "multi-step-band"
description = "Band with multiple steps"
trigger = "band.multi"
output = "band.multi.done"

[[steps]]
name = "first"
code = "return { count => 1 };"

[[steps]]
name = "second"
code = "return { count => ($state->{count} // 0) + 1 };"

[[steps]]
name = "third"
code = "return { count => ($state->{count} // 0) + 1, final => 1 };"
EOF
close $fh;

@bands = Clank::Band::discover(extra => [$dir]);
my ($multi) = grep { $_->{name} eq 'multi-step-band' } @bands;
ok($multi, 'multi-step band found');
is(scalar @{$multi->{steps}}, 3, 'multi-step band has 3 steps');
is($multi->{steps}[0]{name}, 'first', 'step 1 name');
is($multi->{steps}[1]{name}, 'second', 'step 2 name');
is($multi->{steps}[2]{name}, 'third', 'step 3 name');

# --- test 3: register and execute a band via bus ---

$band_mod->register_band($multi);

my @received;
$bus->subscribe('band.multi.done', sub {
    my ($ev) = @_;
    push @received, $ev->{payload};
    return undef;
});

my $pub = $bus->publish('band.multi', { start => 1 });
ok($pub->{id}, 'band triggered');

is(scalar @received, 1, 'band published result');
my $result = $received[0];
is($result->{ok}, 1, 'band succeeded');
is($result->{band}, 'multi-step-band', 'band name in result');
is($result->{state}{count}, 3, 'steps executed in order (count=3)');
is($result->{state}{final}, 1, 'final step ran');
is(scalar @{$result->{results}}, 3, '3 step results recorded');

# --- test 4: band with inline code that uses state ---

File::Path::make_path("$dir/state-band");
open $fh, '>', "$dir/state-band/band.toml" or die;
print $fh <<'EOF';
name = "state-band"
description = "Band that threads state through steps"
trigger = "band.state"
output = "band.state.done"

[[steps]]
name = "init"
code = "return { value => 10 };"

[[steps]]
name = "double"
code = "return { value => ($state->{value} // 0) * 2 };"

[[steps]]
name = "add"
code = "return { value => ($state->{value} // 0) + 5 };"
EOF
close $fh;

@bands = Clank::Band::discover(extra => [$dir]);
my ($state_band) = grep { $_->{name} eq 'state-band' } @bands;
$band_mod->register_band($state_band);

@received = ();
$bus->subscribe('band.state.done', sub { my ($ev) = @_; push @received, $ev->{payload}; return undef; });
$bus->publish('band.state', { input => 'test' });
is($received[0]{state}{value}, 25, 'state threaded: 10 * 2 + 5 = 25');

# --- test 5: band with error in step stops execution ---

File::Path::make_path("$dir/error-band");
open $fh, '>', "$dir/error-band/band.toml" or die;
print $fh <<'EOF';
name = "error-band"
description = "Band where middle step fails"
trigger = "band.error"
output = "band.error.done"

[[steps]]
name = "ok_step"
code = "return { passed => 1 };"

[[steps]]
name = "fail_step"
code = "die 'intentional error';"

[[steps]]
name = "never_reached"
code = "return { should_not_reach => 1 };"
EOF
close $fh;

@bands = Clank::Band::discover(extra => [$dir]);
my ($error_band) = grep { $_->{name} eq 'error-band' } @bands;
$band_mod->register_band($error_band);

@received = ();
$bus->subscribe('band.error.done', sub { my ($ev) = @_; push @received, $ev->{payload}; return undef; });
$bus->publish('band.error', {});
is($received[0]{ok}, 0, 'band failed on error');
is(scalar @{$received[0]{results}}, 1, 'only 1 step completed before error');
is(exists $received[0]{state}{should_not_reach}, '', 'unreachable step did not run');

# --- test 6: nonexistent file returns undef ---

my $bad = Clank::Band::parse_band("/nonexistent/file.toml");
ok(!$bad, 'nonexistent file returns undef');

# --- test 7: list and get bands ---

my $list = $band_mod->list_bands;
ok(@$list >= 3, 'list_bands returns registered bands');
ok(grep { $_ eq 'multi-step-band' } @$list, 'multi-step-band in list');

my $got = $band_mod->get_band('multi-step-band');
ok($got, 'get_band returns band');
is($got->{name}, 'multi-step-band', 'get_band returns correct band');

# --- test 8: band.toml from project bands/ directory ---

@bands = Clank::Band::discover();
my @names = map { $_->{name} } @bands;
ok(grep { $_ eq 'log-event' } @names, 'project bands/ discovered');

done_testing();
