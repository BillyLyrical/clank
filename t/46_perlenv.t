use strict; use warnings;
use Test::More;
use lib 'lib';

# Test Perl Execution Environment: neurosymbolic loop.

use Clank::Store;
use Clank::Bus;
use Clank::WorldModel;
use Clank::PerlEnv;

# --- setup ---

my $store = Clank::Store->new(db => ':memory:');
my $bus = Clank::Bus->new(store => $store, sender => 'test');
my $wm = Clank::WorldModel->new(store => $store);

my $env = Clank::PerlEnv->new(
    store       => $store,
    bus         => $bus,
    world_model => $wm,
);
$env->register(Claw::Mock::API->new(bus => $bus, store => $store));

# --- test 1: basic execution ---

my @results;
$bus->subscribe('perl_env.result', sub { my ($ev) = @_; push @results, $ev->{payload}; return undef; });

my $pub = $bus->publish('perl.execute', { code => 'print "hello"' });
my $r = $pub->{results}[0];
ok($r->{ok}, 'basic execution ok');
is($r->{stdout}, 'hello', 'stdout captured');
is($r->{exit_code}, 0, 'exit code 0');

# --- test 2: execution with exit code ---

$pub = $bus->publish('perl.execute', { code => 'exit 42' });
$r = $pub->{results}[0];
is($r->{ok}, 0, 'nonzero exit not ok');
is($r->{exit_code}, 42, 'exit code preserved');

# --- test 3: execution with stderr ---

$pub = $bus->publish('perl.execute', { code => 'warn "oops"; exit 1' });
$r = $pub->{results}[0];
like($r->{stderr}, qr/oops/, 'stderr captured');

# --- test 4: key=value extraction ---

$pub = $bus->publish('perl.execute', { code => 'print "port=5432\n"' });
$r = $pub->{results}[0];
ok($r->{ok}, 'key=value execution ok');
ok(@{$r->{facts}}, 'facts extracted from key=value output');

# --- test 5: facts stored in world model ---

$pub = $bus->publish('perl.execute', {
    code => 'print "db_host=localhost\n"; print "db_port=5432\n"'
});
$r = $pub->{results}[0];
ok($r->{ok}, 'multi-fact execution ok');
ok(@{$r->{facts}} >= 2, 'multiple facts stored');

# Verify facts are in the world model.
my $entities = $wm->search_entities('db_host');
ok(@$entities >= 1, 'db_host entity found in world model');
my $ent = $entities->[0];
is($ent->{type}, 'key_value', 'entity type is key_value');

# --- test 6: JSON output extraction ---

$pub = $bus->publish('perl.execute', {
    code => 'use JSON::PP; print encode_json({ status => "ok", count => 42 })'
});
$r = $pub->{results}[0];
ok($r->{ok}, 'JSON execution ok');
my @json_facts = grep { $_->{entity_type} eq 'json_result' } @{$r->{facts}};
ok(@json_facts, 'JSON result fact extracted');

# --- test 7: result event published ---

ok(@results >= 1, 'perl_env.result event published');
like($results[-1]{stdout} // '', qr/hello|ok|db_/, 'result event has stdout');

# --- test 8: quick eval (no side effects) ---

$pub = $bus->publish('perl.eval', { code => 'print 2 + 2' });
$r = $pub->{results}[0];
ok($r->{ok}, 'eval ok');
is($r->{stdout}, '4', 'eval returns correct result');

# Verify no new facts from eval.
my $facts_before = scalar @{ $wm->query_facts() };
$bus->publish('perl.eval', { code => 'print "test"' });
my $facts_after = scalar @{ $wm->query_facts() };
is($facts_after, $facts_before, 'eval does not store facts');

# --- test 9: empty code returns error ---

$pub = $bus->publish('perl.execute', { code => '' });
$r = $pub->{results}[0];
is($r->{ok}, 0, 'empty code returns error');

# --- test 10: timeout ---

$env->{timeout} = 1;
$pub = $bus->publish('perl.execute', { code => 'sleep 10' });
$r = $pub->{results}[0];
is($r->{ok}, 0, 'timeout returns error');
like($r->{error} // '', qr/timed out/, 'timeout error message');
$env->{timeout} = 30;   # restore

done_testing();

# === MOCK API ===

package Claw::Mock::API;
sub new {
    my ($class, %args) = @_;
    return bless { bus => $args{bus}, store => $args{store} }, $class;
}
sub bus   { $_[0]->{bus} }
sub store { $_[0]->{store} }
sub on    { return 1 }
sub register_tool { return }
sub register_command { return }
sub track_sub { return 1 }
sub ui { return undef }
sub session { return undef }
sub wit_name { return 'test' }
1;
