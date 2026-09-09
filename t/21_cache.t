#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

use Clank::Store;
use Clank::Cache;

my $store = Clank::Store->new(db => ':memory:');

# === Test 1: Construction ===

subtest 'Construction with defaults' => sub {
    my $cache = Clank::Cache->new(store => $store);
    isa_ok($cache, 'Clank::Cache');
    my $s = $cache->stats;
    is($s->{hits}, 0, 'starts with zero hits');
    is($s->{entries}, 0, 'starts with zero entries');
};

# === Test 2: Set and get ===

subtest 'Set and get basic' => sub {
    my $c = Clank::Cache->new(store => Clank::Store->new(db => ':memory:'));

    $c->set('key1', { answer => 42 });
    my $val = $c->get('key1');
    is_deeply($val, { answer => 42 }, 'retrieved value matches');
};

subtest 'Get miss returns undef' => sub {
    my $c = Clank::Cache->new(store => Clank::Store->new(db => ':memory:'));
    my $val = $c->get('nonexistent');
    is($val, undef, 'miss returns undef');
};

# === Test 3: Key generation ===

subtest 'make_key is deterministic' => sub {
    my $k1 = Clank::Cache->make_key(model => 'gpt-4o', messages => [{ role => 'user', content => 'hi' }]);
    my $k2 = Clank::Cache->make_key(model => 'gpt-4o', messages => [{ role => 'user', content => 'hi' }]);
    is($k1, $k2, 'same input produces same key');

    my $k3 = Clank::Cache->make_key(model => 'gpt-4o', messages => [{ role => 'user', content => 'bye' }]);
    ok($k1 ne $k3, 'different input produces different key');

    my $k4 = Clank::Cache->make_key(model => 'gpt-4o-mini', messages => [{ role => 'user', content => 'hi' }]);
    ok($k1 ne $k4, 'different model produces different key');
};

# === Test 4: TTL expiration ===

subtest 'Entry expires after TTL' => sub {
    my $c = Clank::Cache->new(store => Clank::Store->new(db => ':memory:'), ttl_ms => 1);

    $c->set('expire_me', 'value', ttl_ms => 1);
    ok(defined $c->get('expire_me'), 'immediately available');

    select(undef, undef, undef, 0.01);   # sleep 10ms > 1ms TTL
    my $val = $c->get('expire_me');
    is($val, undef, 'expired entry returns undef');
};

# === Test 5: Namespace isolation ===

subtest 'Namespaces are isolated' => sub {
    my $store2 = Clank::Store->new(db => ':memory:');
    my $c_llm = Clank::Cache->new(store => $store2, namespace => 'llm');
    my $c_wm  = Clank::Cache->new(store => $store2, namespace => 'worldmodel');

    $c_llm->set('key1', 'llm_value');
    $c_wm->set('key1', 'wm_value');

    is($c_llm->get('key1'), 'llm_value', 'llm namespace');
    is($c_wm->get('key1'), 'wm_value', 'worldmodel namespace');

    $c_llm->clear;
    is($c_llm->get('key1'), undef, 'llm cleared');
    is($c_wm->get('key1'), 'wm_value', 'worldmodel untouched');
};

# === Test 6: Invalidate ===

subtest 'Invalidate specific key' => sub {
    my $c = Clank::Cache->new(store => Clank::Store->new(db => ':memory:'));
    $c->set('a', 1);
    $c->set('b', 2);

    $c->invalidate('a');
    is($c->get('a'), undef, 'a invalidated');
    is($c->get('b'), 2, 'b still present');
};

# === Test 7: Purge ===

subtest 'Purge removes expired entries' => sub {
    my $c = Clank::Cache->new(store => Clank::Store->new(db => ':memory:'));
    $c->set('keep', 'forever', ttl_ms => 100_000);
    $c->set('drop', 'soon', ttl_ms => 1);

    select(undef, undef, undef, 0.01);
    my $purged = $c->purge;
    ok($purged >= 1, 'purged at least one entry');
    is($c->get('keep'), 'forever', 'kept non-expired');
    is($c->get('drop'), undef, 'dropped expired');
};

# === Test 8: Stats ===

subtest 'Stats tracking' => sub {
    my $c = Clank::Cache->new(store => Clank::Store->new(db => ':memory:'));
    $c->set('x', 1);
    $c->get('x');    # hit
    $c->get('y');    # miss

    my $s = $c->stats;
    is($s->{hits}, 1, 'one hit');
    is($s->{misses}, 1, 'one miss');
    is($s->{sets}, 1, 'one set');
    ok($s->{hit_rate} == 0.5, '50% hit rate');
};

# === Test 9: Overwrite ===

subtest 'Set overwrites existing key' => sub {
    my $c = Clank::Cache->new(store => Clank::Store->new(db => ':memory:'));
    $c->set('k', 'old');
    $c->set('k', 'new');
    is($c->get('k'), 'new', 'value overwritten');
};

# === Test 10: Max entries eviction ===

subtest 'Eviction when max_entries exceeded' => sub {
    my $c = Clank::Cache->new(store => Clank::Store->new(db => ':memory:'), max_entries => 5);

    for my $i (1..6) {
        $c->set("k$i", $i);
    }

    my $s = $c->stats;
    ok($s->{entries} <= 5, 'entries within limit');
    ok($s->{evictions} > 0, 'evictions occurred');
};

# === Test 11: Bus events ===

subtest 'Cache publishes events to bus' => sub {
    my $store3 = Clank::Store->new(db => ':memory:');
    require Clank::Bus;
    my $bus = Clank::Bus->new(store => $store3);

    my $c = Clank::Cache->new(store => $store3, bus => $bus);
    my @events;
    $bus->subscribe('cache.*', sub { push @events, $_[0]{topic} }, name => 'test');

    $c->set('ev', 'val');
    $c->get('ev');
    $c->get('nope');

    ok(grep { $_ eq 'cache.hit' } @events, 'cache.hit published');
    ok(grep { $_ eq 'cache.miss' } @events, 'cache.miss published');
};

# === Test 12: Complex values ===

subtest 'Store complex nested structures' => sub {
    my $c = Clank::Cache->new(store => Clank::Store->new(db => ':memory:'));
    my $complex = {
        choices => [{ message => { content => 'hello', tool_calls => [] } }],
        usage   => { prompt_tokens => 10, completion_tokens => 5 },
    };
    $c->set('complex', $complex);
    is_deeply($c->get('complex'), $complex, 'complex structure round-trips');
};

done_testing();
