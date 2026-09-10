#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

use Clank::Store;
use Clank::Memory;

# === Test 1: Construction ===

subtest 'Construction' => sub {
    my $store = Clank::Store->new(db => ':memory:');
    my $m = Clank::Memory->new(store => $store);
    isa_ok($m, 'Clank::Memory');
    my $s = $m->stats;
    is($s->{total}, 0, 'starts empty');
};

# === Test 2: Create and get ===

subtest 'Create and get' => sub {
    my $store = Clank::Store->new(db => ':memory:');
    my $m = Clank::Memory->new(store => $store);

    my $r = $m->create(
        title => 'Use strict always',
        kind  => 'lesson',
        body  => 'Always use strict and warnings in Perl modules.',
        tags  => ['perl', 'style'],
    );
    ok(defined $r->{id}, 'got id');
    ok($r->{id} =~ /^mem_/, 'id has mem_ prefix');

    my $doc = $m->get($r->{id});
    is($doc->{title}, 'Use strict always', 'title');
    is($doc->{kind}, 'lesson', 'kind');
    is($doc->{scope}, 'project', 'default scope');
    is($doc->{status}, 'active', 'default status');
    is_deeply($doc->{tags}, ['perl', 'style'], 'tags decoded');
};

# === Test 3: Kind validation ===

subtest 'Kind validation' => sub {
    my $store = Clank::Store->new(db => ':memory:');
    my $m = Clank::Memory->new(store => $store);

    my $r = $m->create(title => 'test', kind => 'invalid_kind', body => 'x');
    ok(defined $r->{error}, 'rejects invalid kind');
    like($r->{error}, qr/Invalid kind/, 'error message');
};

# === Test 4: Update ===

subtest 'Update' => sub {
    my $store = Clank::Store->new(db => ':memory:');
    my $m = Clank::Memory->new(store => $store);

    my $r = $m->create(title => 'Original', kind => 'note', body => 'v1');
    my $doc = $m->get($r->{id});
    is($doc->{body}, 'v1', 'original body');

    $m->update($r->{id}, body => 'v2', status => 'superseded');
    $doc = $m->get($r->{id});
    is($doc->{body}, 'v2', 'updated body');
    is($doc->{status}, 'superseded', 'updated status');
};

# === Test 5: Delete ===

subtest 'Delete' => sub {
    my $store = Clank::Store->new(db => ':memory:');
    my $m = Clank::Memory->new(store => $store);

    my $r = $m->create(title => 'To delete', kind => 'note', body => 'x');
    ok(defined $m->get($r->{id}), 'exists before delete');

    $m->delete($r->{id});
    ok(!defined $m->get($r->{id}), 'gone after delete');
};

# === Test 6: List with filters ===

subtest 'List with filters' => sub {
    my $store = Clank::Store->new(db => ':memory:');
    my $m = Clank::Memory->new(store => $store);

    $m->create(title => 'Lesson 1', kind => 'lesson', body => 'a');
    $m->create(title => 'Note 1', kind => 'note', body => 'b');
    $m->create(title => 'Lesson 2', kind => 'lesson', body => 'c');

    my $all = $m->list;
    is(scalar @$all, 3, 'all documents');

    my $lessons = $m->list(kind => 'lesson');
    is(scalar @$lessons, 2, 'two lessons');

    my $notes = $m->list(kind => 'note');
    is(scalar @$notes, 1, 'one note');
};

# === Test 7: Search ===

subtest 'Search' => sub {
    my $store = Clank::Store->new(db => ':memory:');
    my $m = Clank::Memory->new(store => $store);

    $m->create(title => 'Database indexing', kind => 'lesson', body => 'Always add indexes for foreign keys.');
    $m->create(title => 'Git branching', kind => 'runbook', body => 'Use feature branches for all changes.');

    my $results = $m->search(query => 'database');
    ok(scalar @$results > 0, 'found results');
    is($results->[0]{title}, 'Database indexing', 'correct result');

    my $empty = $m->search(query => 'nonexistent_xyz');
    is(scalar @$empty, 0, 'no results for bad query');
};

# === Test 8: Stats ===

subtest 'Stats' => sub {
    my $store = Clank::Store->new(db => ':memory:');
    my $m = Clank::Memory->new(store => $store);

    $m->create(title => 'L1', kind => 'lesson', body => 'a');
    $m->create(title => 'L2', kind => 'lesson', body => 'b');
    $m->create(title => 'N1', kind => 'note', body => 'c', scope => 'user');

    my $s = $m->stats;
    is($s->{total}, 3, 'total');
    is($s->{active}, 3, 'all active');
    is($s->{by_kind}{lesson}, 2, 'two lessons');
    is($s->{by_kind}{note}, 1, 'one note');
    is($s->{by_scope}{project}, 2, 'two project-scoped');
    is($s->{by_scope}{user}, 1, 'one user-scoped');
};

# === Test 9: All valid kinds ===

subtest 'All valid kinds accepted' => sub {
    my $store = Clank::Store->new(db => ':memory:');
    my $m = Clank::Memory->new(store => $store);

    for my $kind (qw(context decision fact handoff lesson note preference runbook)) {
        my $r = $m->create(title => "Test $kind", kind => $kind, body => 'x');
        ok(defined $r->{id}, "$kind accepted");
    }
    is($m->stats->{total}, 8, 'all 8 created');
};

# === Test 10: Scope and status filters ===

subtest 'Scope and status filters' => sub {
    my $store = Clank::Store->new(db => ':memory:');
    my $m = Clank::Memory->new(store => $store);

    $m->create(title => 'A', kind => 'note', body => 'a', scope => 'project');
    $m->create(title => 'B', kind => 'note', body => 'b', scope => 'user');
    $m->create(title => 'C', kind => 'note', body => 'c', scope => 'project', status => 'rejected');

    my $proj = $m->list(scope => 'project');
    is(scalar @$proj, 2, 'project-scoped');

    my $active = $m->list(status => 'active');
    is(scalar @$active, 2, 'active only');

    my $proj_active = $m->list(scope => 'project', status => 'active');
    is(scalar @$proj_active, 1, 'project + active');
};

done_testing();
