use strict; use warnings;
use Test::More;
use lib 'lib';

# Test computational escalation: cheapest correct tool first.

use Clank::Store;
use Clank::Escalation;
use Clank::Rules::Engine;

# --- setup: in-memory store + components ---

my $store = Clank::Store->new(db => ':memory:');
my $engine = Clank::Rules::Engine->new(store => $store);

# Initialize crystallized_rules schema.
require Clank::Crystallizer;
my $cryst = Clank::Crystallizer->new(store => $store);

# --- test 1: escalation with no data returns undef (LLM fallback) ---

my $esc = Clank::Escalation->new(store => $store, engine => $engine);
my $result = $esc->_check_crystallized('what is the port?');
ok(!$result, 'no crystallized rules → undef');

$result = $esc->_check_world_model('what is the port?');
ok(!$result, 'no world model facts → undef');

$result = $esc->_check_rules_engine('what is the port?');
ok(!$result, 'no rules engine match → undef');

# --- test 2: crystallized rule matching ---

# Insert a rule directly into the crystallized_rules table.
$store->dbh->do(q{
    INSERT INTO crystallized_rules (name, rule_type, condition_def, action_def, confidence, source, created_at)
    VALUES (?, ?, ?, ?, ?, ?, ?)
}, undef,
    'fact_default_port', 'fact',
    'default port',
    '{"type":"assert","value":"The default PostgreSQL port is 5432"}',
    0.9, 'test', time() * 1000);

$esc = Clank::Escalation->new(store => $store, engine => $engine, crystallizer => $cryst);

$result = $esc->_check_crystallized('what is the default port?');
ok($result, 'crystallized rule matches');
like($result, qr/5432/, 'crystallized rule returns correct value');

# Negative: unrelated prompt (no keyword overlap with "default port")
$result = $esc->_check_crystallized('describe the color of the sky');
ok(!$result, 'crystallized rule does not match unrelated prompt');

# --- test 3: world model fact matching ---

# Add an entity to the world model.
require Clank::WorldModel;
my $wm = Clank::WorldModel->new(store => $store);
$wm->add_entity(id => 'pg_port', type => 'config', name => 'PostgreSQL port',
    attributes => { value => '5432', description => 'default PostgreSQL port' });

$esc = Clank::Escalation->new(store => $store, engine => $engine, world_model => $wm);

$result = $esc->_check_world_model('what is the postgresql port?');
ok($result, 'world model matches');
like($result, qr/5432/, 'world model returns correct value');
like($result, qr/PostgreSQL port/, 'world model returns entity name');

# --- test 4: rules engine matching ---

use Clank::Rules::Rule;
my $rule = Clank::Rules::Rule->new(
    name     => 'port_rule',
    type     => 'pattern',
    priority => 80,
    match    => qr/default port/i,
    action   => sub { return { value => 'The default port is 5432' } },
    weight   => 0.9,
);
$engine->add($rule);

$esc = Clank::Escalation->new(store => $store, engine => $engine, world_model => $wm);

$result = $esc->_check_rules_engine('what is the default port?');
ok($result, 'rules engine matches');
like($result, qr/5432/, 'rules engine returns correct value');

# --- test 5: escalation priority (crystallized > world model > engine) ---

# All three paths should match "default port". Crystallized should win.
$esc = Clank::Escalation->new(
    store => $store, engine => $engine, world_model => $wm,
    crystallizer => Clank::Crystallizer->new(store => $store),
);

# Test each path directly
my $cr = $esc->_check_crystallized('what is the default port?');
my $wm_r = $esc->_check_world_model('what is the default port?');
my $en_r = $esc->_check_rules_engine('what is the default port?');

ok($cr, 'crystallized path matches');
ok($wm_r, 'world model path matches');
ok($en_r, 'rules engine path matches');

# Crystallized should be cheapest (returned first)
like($cr, qr/5432/, 'crystallized returns correct value');

# --- test 6: mark_used increments use_count ---

my $before = $store->dbh->selectrow_array(
    'SELECT use_count FROM crystallized_rules WHERE name = ?', undef, 'fact_default_port');
$esc->_check_crystallized('what is the default port?');
my $after = $store->dbh->selectrow_array(
    'SELECT use_count FROM crystallized_rules WHERE name = ?', undef, 'fact_default_port');
ok($after > $before, 'mark_used incremented use_count');

# --- test 7: crystallize_result stores new rules ---

$esc = Clank::Escalation->new(store => $store, engine => $engine, crystallizer => $cryst);

my $registered = $esc->crystallize_result(
    'what is the cache TTL?',
    'The cache TTL is 300 seconds.'
);
ok($registered > 0, 'crystallize_result stored rules');

my $rules = $cryst->list_rules;
my ($ttl) = grep { $_->{name} =~ /cache.*ttl/i } @$rules;
ok($ttl, 'crystallized TTL rule exists');
like($ttl->{action_def}, qr/300/, 'crystallized rule contains correct value');

# --- test 8: empty prompt returns undef ---

$esc = Clank::Escalation->new(store => $store);
$result = $esc->_check_crystallized('');
ok(!$result, 'empty prompt → undef');

$result = $esc->_check_world_model('');
ok(!$result, 'empty prompt → undef');

done_testing();
