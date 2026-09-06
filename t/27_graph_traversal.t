#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

use Clam::Store;
use Clam::WorldModel;

my $store = Clam::Store->new(db => ':memory:');
my $wm = Clam::WorldModel->new(store => $store);

# Build a test graph:
#   Alice --knows--> Bob --knows--> Charlie --knows--> Dave
#   Alice --knows--> Eve
#   Eve --works_at--> TechCorp
#   Bob --works_at--> TechCorp

my $alice = $wm->add_entity(type => 'person', name => 'Alice');
my $bob   = $wm->add_entity(type => 'person', name => 'Bob');
my $charlie = $wm->add_entity(type => 'person', name => 'Charlie');
my $dave  = $wm->add_entity(type => 'person', name => 'Dave');
my $eve   = $wm->add_entity(type => 'person', name => 'Eve');
my $corp  = $wm->add_entity(type => 'org', name => 'TechCorp');

$wm->add_relation(source_id => $alice, target_id => $bob, type => 'knows', confidence => 1.0);
$wm->add_relation(source_id => $bob, target_id => $charlie, type => 'knows', confidence => 0.9);
$wm->add_relation(source_id => $charlie, target_id => $dave, type => 'knows', confidence => 0.8);
$wm->add_relation(source_id => $alice, target_id => $eve, type => 'knows', confidence => 1.0);
$wm->add_relation(source_id => $eve, target_id => $corp, type => 'works_at', confidence => 1.0);
$wm->add_relation(source_id => $bob, target_id => $corp, type => 'works_at', confidence => 0.9);

# === Test 1: Neighbors ===

subtest 'Neighbors - outgoing' => sub {
    my $n = $wm->neighbors($alice, direction => 'out');
    ok(scalar @$n == 2, 'Alice knows 2 people');
    my @names = map { $_->{entity}{name} } @$n;
    ok(grep { $_ eq 'Bob' } @names, 'knows Bob');
    ok(grep { $_ eq 'Eve' } @names, 'knows Eve');
};

subtest 'Neighbors - incoming' => sub {
    my $n = $wm->neighbors($corp, direction => 'in');
    ok(scalar @$n == 2, '2 people work at TechCorp');
    my @names = map { $_->{entity}{name} } @$n;
    ok(grep { $_ eq 'Eve' } @names, 'Eve works there');
    ok(grep { $_ eq 'Bob' } @names, 'Bob works there');
};

subtest 'Neighbors - both' => sub {
    my $n = $wm->neighbors($bob, direction => 'both');
    ok(scalar @$n >= 3, 'Bob has at least 3 connections');
};

subtest 'Neighbors - filter by relation type' => sub {
    my $n = $wm->neighbors($alice, direction => 'out', type => 'knows');
    ok(scalar @$n == 2, 'Alice knows 2 people');
    my $n2 = $wm->neighbors($eve, direction => 'out', type => 'works_at');
    ok(scalar @$n2 == 1, 'Eve works at 1 place');
};

# === Test 2: Walk ===

subtest 'Walk - BFS traversal' => sub {
    my $w = $wm->walk($alice, max_hops => 1);
    ok(scalar @$w == 2, '1 hop: Bob and Eve');

    $w = $wm->walk($alice, max_hops => 2);
    ok(scalar @$w >= 3, '2 hops: Bob, Eve, Charlie');

    $w = $wm->walk($alice, max_hops => 10);
    ok(scalar @$w == 5, 'full traversal: all 5 reachable');
};

subtest 'Walk - returns distance' => sub {
    my $w = $wm->walk($alice, max_hops => 3);
    my %by_name = map { $_->{entity}{name} => $_ } @$w;
    is($by_name{Bob}{distance}, 1, 'Bob is 1 hop');
    is($by_name{Charlie}{distance}, 2, 'Charlie is 2 hops');
    is($by_name{Dave}{distance}, 3, 'Dave is 3 hops');
};

subtest 'Walk - via relation info' => sub {
    my $w = $wm->walk($alice, max_hops => 1);
    my $bob_hop = (grep { $_->{entity}{name} eq 'Bob' } @$w)[0];
    is($bob_hop->{via}{type}, 'knows', 'relation type preserved');
    ok($bob_hop->{via}{confidence} > 0, 'confidence preserved');
};

subtest 'Walk - filter by type' => sub {
    my $w = $wm->walk($alice, max_hops => 3, type => 'knows');
    my @names = map { $_->{entity}{name} } @$w;
    ok(grep { $_ eq 'Charlie' } @names, 'follows knows edges');
    ok(!grep { $_ eq 'TechCorp' } @names, 'does not follow works_at edges');
};

subtest 'Walk - limit' => sub {
    my $w = $wm->walk($alice, max_hops => 10, limit => 2);
    ok(scalar @$w <= 2, 'limit respected');
};

# === Test 3: Path ===

subtest 'Path - direct connection' => sub {
    my $p = $wm->path($alice, $bob);
    ok(defined $p, 'path exists');
    is(scalar @$p, 2, 'direct: 2 nodes');
    is($p->[0]{entity_id}, $alice, 'starts at Alice');
    is($p->[1]{entity_id}, $bob, 'ends at Bob');
    is($p->[1]{via_type}, 'knows', 'via type preserved');
};

subtest 'Path - multi-hop' => sub {
    my $p = $wm->path($alice, $charlie);
    ok(defined $p, 'path exists');
    is(scalar @$p, 3, '2 hops: 3 nodes');
    is($p->[0]{entity_id}, $alice, 'starts at Alice');
    is($p->[1]{entity_id}, $bob, 'through Bob');
    is($p->[2]{entity_id}, $charlie, 'ends at Charlie');
};

subtest 'Path - long chain' => sub {
    my $p = $wm->path($alice, $dave);
    ok(defined $p, 'path exists');
    is(scalar @$p, 4, '3 hops: 4 nodes');
};

subtest 'Path - no path' => sub {
    my $p = $wm->path($dave, $alice);
    is($p, undef, 'no path from Dave to Alice (one-directional)');
};

subtest 'Path - max hops limits search' => sub {
    my $p = $wm->path($alice, $dave, max_hops => 2);
    is($p, undef, 'no path within 2 hops');
};

# === Test 4: Edge cases ===

subtest 'Neighbors of nonexistent entity' => sub {
    my $n = $wm->neighbors('nonexistent');
    is(scalar @$n, 0, 'empty result');
};

subtest 'Walk from leaf node' => sub {
    my $w = $wm->walk($dave, max_hops => 3);
    is(scalar @$w, 0, 'Dave has no outgoing edges');
};

subtest 'Path to self' => sub {
    my $p = $wm->path($alice, $alice);
    ok(defined $p, 'path to self exists');
    is(scalar @$p, 1, 'single node');
};

done_testing();
