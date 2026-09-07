#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

use AI::Clam::Store;
use AI::Clam::WorldModel;
use AI::Clam::Logic::Taxonomy;

my $store = AI::Clam::Store->new(db => ':memory:');
my $wm    = AI::Clam::WorldModel->new(store => $store);

# === Test 1: Construction ===

subtest 'Construction' => sub {
    my $tx = AI::Clam::Logic::Taxonomy->new(world_model => $wm);
    isa_ok($tx, 'AI::Clam::Logic::Taxonomy');
    my $s = $tx->stats;
    is($s->{categories}, 0, 'starts empty');
};

# === Test 2: Create root category ===

subtest 'Create root category' => sub {
    my $tx = AI::Clam::Logic::Taxonomy->new(world_model => AI::Clam::WorldModel->new(store => AI::Clam::Store->new(db => ':memory:')));

    my $id = $tx->create_category(name => 'language', type => 'entity_type');
    ok($id, 'category created');

    my $cat = $tx->get_category($id);
    is($cat->{name}, 'language', 'name matches');
    is($cat->{type}, 'entity_type', 'type matches');
    is($cat->{parent_id}, undef, 'no parent (root)');
};

# === Test 3: Create child category ===

subtest 'Create child category' => sub {
    my $tx = AI::Clam::Logic::Taxonomy->new(world_model => AI::Clam::WorldModel->new(store => AI::Clam::Store->new(db => ':memory:')));

    my $lang = $tx->create_category(name => 'language', type => 'entity_type');
    my $script = $tx->create_category(name => 'scripting', type => 'entity_type', parent_id => $lang);
    my $compiled = $tx->create_category(name => 'compiled', type => 'entity_type', parent_id => $lang);

    my $kids = $tx->children($lang);
    is(scalar @$kids, 2, 'language has 2 children');

    my @names = sort map { $_->{name} } @$kids;
    is_deeply(\@names, ['compiled', 'scripting'], 'children are scripting and compiled');
};

# === Test 4: Ancestors ===

subtest 'Ancestors' => sub {
    my $tx = AI::Clam::Logic::Taxonomy->new(world_model => AI::Clam::WorldModel->new(store => AI::Clam::Store->new(db => ':memory:')));

    my $root = $tx->create_category(name => 'knowledge', type => 'belief_category');
    my $sub = $tx->create_category(name => 'technical', type => 'belief_category', parent_id => $root);
    my $leaf = $tx->create_category(name => 'programming', type => 'belief_category', parent_id => $sub);

    my $path = $tx->ancestors($leaf);
    is(scalar @$path, 3, 'path has 3 nodes');
    is($path->[0]{name}, 'knowledge', 'root first');
    is($path->[2]{name}, 'programming', 'leaf last');
};

# === Test 5: Descendants ===

subtest 'Descendants' => sub {
    my $tx = AI::Clam::Logic::Taxonomy->new(world_model => AI::Clam::WorldModel->new(store => AI::Clam::Store->new(db => ':memory:')));

    my $root = $tx->create_category(name => 'all', type => 'entity_type');
    my $a = $tx->create_category(name => 'A', type => 'entity_type', parent_id => $root);
    my $b = $tx->create_category(name => 'B', type => 'entity_type', parent_id => $root);
    my $c = $tx->create_category(name => 'C', type => 'entity_type', parent_id => $a);

    my $desc = $tx->descendants($root);
    is(scalar @$desc, 3, 'root has 3 descendants');
};

# === Test 6: Descendants depth limit ===

subtest 'Descendants depth limit' => sub {
    my $tx = AI::Clam::Logic::Taxonomy->new(world_model => AI::Clam::WorldModel->new(store => AI::Clam::Store->new(db => ':memory:')));

    my $root = $tx->create_category(name => 'root', type => 'x');
    my $a = $tx->create_category(name => 'A', type => 'x', parent_id => $root);
    my $b = $tx->create_category(name => 'B', type => 'x', parent_id => $a);
    my $c = $tx->create_category(name => 'C', type => 'x', parent_id => $b);

    my $d1 = $tx->descendants($root, max_depth => 1);
    is(scalar @$d1, 1, 'depth 1 only sees A');

    my $d2 = $tx->descendants($root, max_depth => 2);
    is(scalar @$d2, 2, 'depth 2 sees A and B');
};

# === Test 7: Properties ===

subtest 'Properties' => sub {
    my $tx = AI::Clam::Logic::Taxonomy->new(world_model => AI::Clam::WorldModel->new(store => AI::Clam::Store->new(db => ':memory:')));

    my $id = $tx->create_category(name => 'test', type => 'x');
    $tx->set_property(node_id => $id, key => 'color', value => 'blue');
    $tx->set_property(node_id => $id, key => 'size', value => 'large');

    is($tx->get_property(node_id => $id, key => 'color'), 'blue', 'get property');
    my $all = $tx->all_properties($id);
    is(scalar keys %$all, 2, 'two properties');
    is($all->{size}, 'large', 'all_properties includes size');
};

# === Test 8: Property inheritance ===

subtest 'Property inheritance' => sub {
    my $tx = AI::Clam::Logic::Taxonomy->new(world_model => AI::Clam::WorldModel->new(store => AI::Clam::Store->new(db => ':memory:')));

    my $root = $tx->create_category(name => 'root', type => 'x');
    $tx->set_property(node_id => $root, key => 'lang', value => 'en');
    $tx->set_property(node_id => $root, key => 'color', value => 'blue');

    my $child = $tx->create_category(name => 'child', type => 'x', parent_id => $root);
    $tx->set_property(node_id => $child, key => 'color', value => 'red');

    my $props = $tx->inherited_properties($child);
    is($props->{lang}, 'en', 'inherited lang from parent');
    is($props->{color}, 'red', 'child overrides parent color');
};

# === Test 9: Deep inheritance chain ===

subtest 'Deep inheritance' => sub {
    my $tx = AI::Clam::Logic::Taxonomy->new(world_model => AI::Clam::WorldModel->new(store => AI::Clam::Store->new(db => ':memory:')));

    my $a = $tx->create_category(name => 'A', type => 'x');
    $tx->set_property(node_id => $a, key => 'x', value => '1');
    $tx->set_property(node_id => $a, key => 'y', value => '1');

    my $b = $tx->create_category(name => 'B', type => 'x', parent_id => $a);
    $tx->set_property(node_id => $b, key => 'y', value => '2');
    $tx->set_property(node_id => $b, key => 'z', value => '2');

    my $c = $tx->create_category(name => 'C', type => 'x', parent_id => $b);
    $tx->set_property(node_id => $c, key => 'z', value => '3');

    my $props = $tx->inherited_properties($c);
    is($props->{x}, '1', 'inherited from grandparent');
    is($props->{y}, '2', 'overridden by parent');
    is($props->{z}, '3', 'overridden by self');
};

# === Test 10: Delete property ===

subtest 'Delete property' => sub {
    my $tx = AI::Clam::Logic::Taxonomy->new(world_model => AI::Clam::WorldModel->new(store => AI::Clam::Store->new(db => ':memory:')));

    my $id = $tx->create_category(name => 'test', type => 'x');
    $tx->set_property(node_id => $id, key => 'k', value => 'v');
    $tx->delete_property(node_id => $id, key => 'k');
    is($tx->get_property(node_id => $id, key => 'k'), undef, 'property deleted');
};

# === Test 11: Map entity to category ===

subtest 'Map entity' => sub {
    my $tx = AI::Clam::Logic::Taxonomy->new(world_model => AI::Clam::WorldModel->new(store => AI::Clam::Store->new(db => ':memory:')));

    my $lang = $tx->create_category(name => 'language', type => 'entity_type');
    my $perl = $tx->create_category(name => 'Perl', type => 'entity_type', parent_id => $lang);

    $wm->add_entity(id => 'perl', type => 'language', name => 'Perl');
    $tx->map_entity(entity_id => 'perl', node_id => $perl);

    my $cats = $tx->entity_categories('perl');
    ok(scalar @$cats >= 2, 'entity has categories (Perl + ancestors)');
    my @cat_names = map { $_->{name} } @$cats;
    ok(grep { $_ eq 'Perl' } @cat_names, 'Perl category present');
    ok(grep { $_ eq 'language' } @cat_names, 'language category present via ancestor');
};

# === Test 12: Map belief to category ===

subtest 'Map belief' => sub {
    my $tx = AI::Clam::Logic::Taxonomy->new(world_model => AI::Clam::WorldModel->new(store => AI::Clam::Store->new(db => ':memory:')));

    my $factual = $tx->create_category(name => 'factual', type => 'belief_category');
    my $tech = $tx->create_category(name => 'technical', type => 'belief_category', parent_id => $factual);

    my $bid = $wm->believe(statement => 'Perl is a language', confidence => 0.9);
    $tx->map_belief(belief_id => $bid, node_id => $tech);

    my $cats = $tx->belief_categories($bid);
    ok(scalar @$cats >= 2, 'belief has categories');
};

# === Test 13: Map goal to category ===

subtest 'Map goal' => sub {
    my $tx = AI::Clam::Logic::Taxonomy->new(world_model => AI::Clam::WorldModel->new(store => AI::Clam::Store->new(db => ':memory:')));

    my $learn = $tx->create_category(name => 'learn', type => 'goal_category');
    $tx->map_goal(goal_id => 'g1', node_id => $learn);

    my @found = $tx->_dbh->selectall_arrayref(
        'SELECT * FROM taxonomy_map WHERE goal_id = ?', { Slice => {} }, 'g1');
    is(scalar @found, 1, 'goal mapped');
};

# === Test 14: entities_in_category ===

subtest 'entities_in_category' => sub {
    my $store2 = AI::Clam::Store->new(db => ':memory:');
    my $wm2 = AI::Clam::WorldModel->new(store => $store2);
    my $tx = AI::Clam::Logic::Taxonomy->new(world_model => $wm2);

    my $lang = $tx->create_category(name => 'language', type => 'entity_type');
    my $script = $tx->create_category(name => 'scripting', type => 'entity_type', parent_id => $lang);

    $wm2->add_entity(id => 'perl', type => 'language', name => 'Perl');
    $wm2->add_entity(id => 'python', type => 'language', name => 'Python');
    $tx->map_entity(entity_id => 'perl', node_id => $script);
    $tx->map_entity(entity_id => 'python', node_id => $script);

    my $entities = $tx->entities_in_category($lang);
    ok(scalar @$entities >= 2, 'found both entities under language');
};

# === Test 15: beliefs_in_category ===

subtest 'beliefs_in_category' => sub {
    my $store2 = AI::Clam::Store->new(db => ':memory:');
    my $wm2 = AI::Clam::WorldModel->new(store => $store2);
    my $tx = AI::Clam::Logic::Taxonomy->new(world_model => $wm2);

    my $factual = $tx->create_category(name => 'factual', type => 'belief_category');
    my $tech = $tx->create_category(name => 'tech', type => 'belief_category', parent_id => $factual);

    my $b1 = $wm2->believe(statement => 'Perl is a language', confidence => 0.9, source => 'user');
    my $b2 = $wm2->believe(statement => 'Python is a language', confidence => 0.8, source => 'user');
    $tx->map_belief(belief_id => $b1, node_id => $tech);
    $tx->map_belief(belief_id => $b2, node_id => $tech);

    my $beliefs = $tx->beliefs_in_category($factual);
    ok(scalar @$beliefs >= 2, 'found both beliefs under factual');
};

# === Test 16: Delete category re-parents children ===

subtest 'Delete category re-parents' => sub {
    my $tx = AI::Clam::Logic::Taxonomy->new(world_model => AI::Clam::WorldModel->new(store => AI::Clam::Store->new(db => ':memory:')));

    my $root = $tx->create_category(name => 'root', type => 'x');
    my $mid = $tx->create_category(name => 'mid', type => 'x', parent_id => $root);
    my $leaf = $tx->create_category(name => 'leaf', type => 'x', parent_id => $mid);

    $tx->delete_category($mid);
    my $kids = $tx->children($root);
    my @names = map { $_->{name} } @$kids;
    ok(grep { $_ eq 'leaf' } @names, 'leaf re-parented to root');
};

# === Test 17: Root categories ===

subtest 'Root categories' => sub {
    my $tx = AI::Clam::Logic::Taxonomy->new(world_model => AI::Clam::WorldModel->new(store => AI::Clam::Store->new(db => ':memory:')));

    $tx->create_category(name => 'A', type => 'entity_type');
    $tx->create_category(name => 'B', type => 'belief_category');
    $tx->create_category(name => 'C', type => 'entity_type');

    my $roots = $tx->root_categories(type => 'entity_type');
    is(scalar @$roots, 2, 'two entity_type roots');

    my $all_roots = $tx->root_categories;
    is(scalar @$all_roots, 3, 'all three roots');
};

# === Test 18: Stats ===

subtest 'Stats' => sub {
    my $tx = AI::Clam::Logic::Taxonomy->new(world_model => AI::Clam::WorldModel->new(store => AI::Clam::Store->new(db => ':memory:')));

    my $root = $tx->create_category(name => 'root', type => 'x');
    my $child = $tx->create_category(name => 'child', type => 'x', parent_id => $root);
    $tx->set_property(node_id => $root, key => 'k', value => 'v');

    $wm->add_entity(id => 'e1', type => 'thing', name => 'E1');
    $tx->map_entity(entity_id => 'e1', node_id => $child);

    my $s = $tx->stats;
    is($s->{categories}, 2, '2 categories');
    is($s->{properties}, 1, '1 property');
    is($s->{mappings}, 1, '1 mapping');
    is($s->{roots}, 1, '1 root');
};

# === Test 19: has_property_inherited ===

subtest 'has_property_inherited' => sub {
    my $tx = AI::Clam::Logic::Taxonomy->new(world_model => AI::Clam::WorldModel->new(store => AI::Clam::Store->new(db => ':memory:')));

    my $root = $tx->create_category(name => 'root', type => 'x');
    $tx->set_property(node_id => $root, key => 'constraint', value => 'stoic');

    my $child = $tx->create_category(name => 'child', type => 'x', parent_id => $root);

    my $val = $tx->has_property_inherited($child, 'constraint');
    is($val, 'stoic', 'inherited constraint found');
};

# === Test 20: entity_under_category ===

subtest 'entity_under_category' => sub {
    my $tx = AI::Clam::Logic::Taxonomy->new(world_model => AI::Clam::WorldModel->new(store => AI::Clam::Store->new(db => ':memory:')));

    my $lang = $tx->create_category(name => 'language', type => 'entity_type');
    my $script = $tx->create_category(name => 'scripting', type => 'entity_type', parent_id => $lang);

    $wm->add_entity(id => 'perl', type => 'language', name => 'Perl');
    $tx->map_entity(entity_id => 'perl', node_id => $script);

    ok($tx->entity_under_category('perl', $script), 'perl is scripting');
    ok($tx->entity_under_category('perl', $lang), 'perl is language (ancestor)');
    ok(!$tx->entity_under_category('perl', $lang) ? 0 : 1, 'perl under lang');
};

# === Test 21: Invalid parent dies ===

subtest 'Invalid parent dies' => sub {
    my $tx = AI::Clam::Logic::Taxonomy->new(world_model => AI::Clam::WorldModel->new(store => AI::Clam::Store->new(db => ':memory:')));

    eval { $tx->create_category(name => 'orphan', type => 'x', parent_id => 'nonexistent') };
    like($@, qr/not found/, 'dies on invalid parent');
};

# === Test 22: beliefs_in_category with min_confidence ===

subtest 'beliefs_in_category confidence filter' => sub {
    my $store2 = AI::Clam::Store->new(db => ':memory:');
    my $wm2 = AI::Clam::WorldModel->new(store => $store2);
    my $tx = AI::Clam::Logic::Taxonomy->new(world_model => $wm2);

    my $cat = $tx->create_category(name => 'facts', type => 'belief_category');
    my $b1 = $wm2->believe(statement => 'High', confidence => 0.9, source => 'user');
    my $b2 = $wm2->believe(statement => 'Low', confidence => 0.2, source => 'user');
    $tx->map_belief(belief_id => $b1, node_id => $cat);
    $tx->map_belief(belief_id => $b2, node_id => $cat);

    my $all = $tx->beliefs_in_category($cat);
    is(scalar @$all, 2, 'all beliefs returned without filter');

    my $high = $tx->beliefs_in_category($cat, min_confidence => 0.5);
    is(scalar @$high, 1, 'only high confidence belief');
};

done_testing;
