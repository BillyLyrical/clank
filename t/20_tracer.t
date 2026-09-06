#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

use Clam::Store;
use Clam::Tracer;
use Time::HiRes qw(sleep clock_gettime CLOCK_MONOTONIC);

my $store = Clam::Store->new(db => ':memory:');

# === Test 1: Basic construction ===

subtest 'Construction' => sub {
    my $t = Clam::Tracer->new(store => $store);
    isa_ok($t, 'Clam::Tracer');
    my $s = $t->stats;
    is($s->{total_spans}, 0, 'starts with zero spans');
};

# === Test 2: Start/end span ===

subtest 'Start and end span' => sub {
    my $t = Clam::Tracer->new(store => Clam::Store->new(db => ':memory:'));

    my $id = $t->start_span('test-span', key => 'value');
    ok(defined $id, 'start_span returns id');
    is($t->current_span, $id, 'current_span is the active span');

    sleep(0.01);
    my $elapsed = $t->end_span($id);
    ok($elapsed > 0, 'end_span returns positive duration');
    is($t->current_span, undef, 'no active span after end');
};

# === Test 3: Implicit end (pop from stack) ===

subtest 'Implicit end via pop' => sub {
    my $t = Clam::Tracer->new(store => Clam::Store->new(db => ':memory:'));

    $t->start_span('outer');
    $t->start_span('inner');
    is(scalar @{$t->{_active}}, 2, 'two spans active');

    $t->end_span;   # pops inner
    is(scalar @{$t->{_active}}, 1, 'one span active after implicit end');

    $t->end_span;   # pops outer
    is(scalar @{$t->{_active}}, 0, 'no spans active');
};

# === Test 4: Nested spans ===

subtest 'Nested spans with parent_id' => sub {
    my $store2 = Clam::Store->new(db => ':memory:');
    my $t = Clam::Tracer->new(store => $store2);

    my $outer = $t->start_span('outer');
    my $inner = $t->start_span('inner');
    $t->end_span($inner);
    $t->end_span($outer);

    my $span = $t->get_span($outer);
    ok($span, 'outer span exists');
    is(scalar @{$span->{children}}, 1, 'outer has one child');
    is($span->{children}[0]{name}, 'inner', 'child is inner span');
    is($span->{children}[0]{parent_id}, $outer, 'child parent_id matches');
};

# === Test 5: trace() convenience ===

subtest 'trace() wraps a code block' => sub {
    my $t = Clam::Tracer->new(store => Clam::Store->new(db => ':memory:'));

    my $result = $t->trace('compute', sub { sleep(0.01); return 42 }, x => 1);
    is($result, 42, 'trace returns code result');

    my $spans = $t->query_spans(name => 'compute');
    is(scalar @$spans, 1, 'span recorded');
    ok($spans->[0]{duration_ms} > 0, 'duration recorded');
    is_deeply($spans->[0]{metadata}, { x => 1 }, 'metadata preserved');
};

subtest 'trace() propagates exceptions' => sub {
    my $t = Clam::Tracer->new(store => Clam::Store->new(db => ':memory:'));

    eval { $t->trace('fail', sub { die "boom" }) };
    like($@, qr/boom/, 'exception propagated');

    # Span should still be ended.
    my $spans = $t->query_spans(name => 'fail');
    is(scalar @$spans, 1, 'span recorded even on die');
};

# === Test 6: Query spans ===

subtest 'Query with filters' => sub {
    my $store3 = Clam::Store->new(db => ':memory:');
    my $t = Clam::Tracer->new(store => $store3);

    $t->start_span('llm.call', topic => 'llm');
    $t->end_span;
    $t->start_span('rule.fire', topic => 'rules');
    $t->end_span;
    $t->start_span('llm.call', topic => 'llm');
    $t->end_span;

    my $llm = $t->query_spans(topic => 'llm');
    is(scalar @$llm, 2, 'filtered by topic');

    my $all = $t->query_spans;
    is(scalar @$all, 3, 'all spans returned');

    my $limited = $t->query_spans(limit => 1);
    is(scalar @$limited, 1, 'limit works');
};

subtest 'Query with min_duration' => sub {
    my $store4 = Clam::Store->new(db => ':memory:');
    my $t = Clam::Tracer->new(store => $store4);

    $t->trace('fast', sub { }, fast => 1);
    $t->trace('slow', sub { sleep(0.02) }, slow => 1);

    my $slow = $t->query_spans(min_duration_ms => 10);
    ok(scalar @$slow >= 1, 'min_duration filter works');
    my @names = map { $_->{name} } @$slow;
    ok(grep { $_ eq 'slow' } @names, 'slow span included');
};

# === Test 7: Stats ===

subtest 'Stats' => sub {
    my $store5 = Clam::Store->new(db => ':memory:');
    my $t = Clam::Tracer->new(store => $store5);

    $t->trace('a', sub { sleep(0.005) }, topic => 'x');
    $t->trace('b', sub { sleep(0.005) }, topic => 'x');
    $t->trace('c', sub { sleep(0.005) }, topic => 'y');

    my $s = $t->stats;
    is($s->{total_spans}, 3, 'total spans');
    ok($s->{avg_duration} > 0, 'avg duration');
    is(scalar @{$s->{by_topic}}, 2, 'two topics');
};

# === Test 8: Trace tree ===

subtest 'Trace tree' => sub {
    my $store6 = Clam::Store->new(db => ':memory:');
    my $t = Clam::Tracer->new(store => $store6);

    my $root = $t->start_span('pipeline');
    $t->start_span('llm_call');
    $t->end_span;
    $t->start_span('rule_validate');
    $t->end_span;
    $t->end_span($root);

    my $tree = $t->trace_tree;
    is(scalar @$tree, 1, 'one root');
    is($tree->[0]{name}, 'pipeline', 'root is pipeline');
    is(scalar @{$tree->[0]{children}}, 2, 'root has two children');
};

# === Test 9: Bus auto-subscribe ===

subtest 'Auto-subscribe traces bus events' => sub {
    my $store7 = Clam::Store->new(db => ':memory:');
    require Clam::Bus;
    my $bus = Clam::Bus->new(store => $store7);

    my $t = Clam::Tracer->new(store => $store7, bus => $bus, auto_subscribe => 1);

    $bus->publish('test.event', { data => 1 });
    $bus->publish('test.other', { data => 2 });

    my $spans = $t->query_spans;
    ok(scalar @$spans >= 2, 'bus events traced');
    my @topics = map { $_->{topic} } @$spans;
    ok(grep { $_ eq 'test.event' } @topics, 'test.event traced');
    ok(grep { $_ eq 'test.other' } @topics, 'test.other traced');
};

# === Test 10: Metadata persistence ===

subtest 'Metadata persisted and retrieved' => sub {
    my $store8 = Clam::Store->new(db => ':memory:');
    my $t = Clam::Tracer->new(store => $store8);

    my $id = $t->start_span('test', str => 'hello', num => 42, nested => { a => 1 });
    $t->end_span($id);

    my $span = $t->get_span($id);
    is($span->{metadata}{str}, 'hello', 'string metadata');
    is($span->{metadata}{num}, 42, 'numeric metadata');
    is_deeply($span->{metadata}{nested}, { a => 1 }, 'nested metadata');
};

done_testing();
