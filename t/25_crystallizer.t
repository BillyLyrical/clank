#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

use Clank::Store;
use Clank::Crystallizer;

my $store = Clank::Store->new(db => ':memory:');

# === Test 1: Construction ===

subtest 'Construction' => sub {
    my $c = Clank::Crystallizer->new(store => $store);
    isa_ok($c, 'Clank::Crystallizer');
    my $s = $c->stats;
    is($s->{total_rules}, 0, 'starts with zero rules');
};

# === Test 2: Crystallize from conversation text ===

subtest 'Crystallize from text' => sub {
    my $c = Clank::Crystallizer->new(store => Clank::Store->new(db => ':memory:'));

    my $count = $c->crystallize(
        conversation => "The capital of France is Paris. France is a country in Europe.",
    );
    ok($count > 0, 'crystallized at least one rule');

    my $rules = $c->list_rules;
    ok(scalar @$rules > 0, 'rules stored');
};

# === Test 3: Crystallize from message arrayref ===

subtest 'Crystallize from messages' => sub {
    my $c = Clank::Crystallizer->new(store => Clank::Store->new(db => ':memory:'));

    my $count = $c->crystallize(conversation => [
        { role => 'user', content => 'What is Perl?' },
        { role => 'assistant', content => 'Perl is a programming language. Perl is used for text processing.' },
    ]);
    ok($count > 0, 'crystallized from messages');
};

# === Test 4: Deduplication ===

subtest 'Duplicate rules are rejected' => sub {
    my $c = Clank::Crystallizer->new(store => Clank::Store->new(db => ':memory:'));

    $c->crystallize(conversation => "Perl is a language.");
    my $count1 = $c->stats->{total_rules};

    $c->crystallize(conversation => "Perl is a language.");
    my $count2 = $c->stats->{total_rules};

    is($count2, $count1, 'no duplicate rules created');
};

# === Test 5: Confidence threshold ===

subtest 'Low confidence rules are rejected' => sub {
    my $c = Clank::Crystallizer->new(store => Clank::Store->new(db => ':memory:'), min_confidence => 0.9);

    # Heuristic extraction produces 0.5-0.6 confidence — all below threshold.
    my $count = $c->crystallize(conversation => "If it rains then the ground gets wet.");
    is($count, 0, 'low confidence rules rejected');
};

# === Test 6: Rule stats ===

subtest 'Stats tracking' => sub {
    my $c = Clank::Crystallizer->new(store => Clank::Store->new(db => ':memory:'));

    $c->crystallize(conversation => "Water is H2O.");
    $c->crystallize(conversation => "Oxygen is O2.");

    my $s = $c->stats;
    is($s->{total_rules}, 2, 'two rules');
    ok($s->{active} == 2, 'both active');
    ok($s->{avg_confidence} > 0, 'avg confidence set');
};

# === Test 7: Get rule by name ===

subtest 'Get rule by name' => sub {
    my $c = Clank::Crystallizer->new(store => Clank::Store->new(db => ':memory:'));

    $c->crystallize(conversation => "Gold is a precious metal.");
    my $rules = $c->list_rules;
    my $name = $rules->[0]{name};

    my $rule = $c->get_rule($name);
    ok(defined $rule, 'found rule by name');
    is($rule->{name}, $name, 'correct rule');
};

# === Test 8: Disable rule ===

subtest 'Disable rule' => sub {
    my $c = Clank::Crystallizer->new(store => Clank::Store->new(db => ':memory:'));

    $c->crystallize(conversation => "Silver is a metal.");
    my $rules = $c->list_rules;
    my $name = $rules->[0]{name};

    $c->disable_rule($name);
    my $active = $c->list_rules;
    is(scalar @$active, 0, 'rule disabled');

    my $all = $c->list_rules(disabled => 1);
    ok(scalar @$all > 0, 'disabled rule visible with flag');
};

# === Test 9: Mark used ===

subtest 'Mark used increments count' => sub {
    my $c = Clank::Crystallizer->new(store => Clank::Store->new(db => ':memory:'));

    $c->crystallize(conversation => "Copper is conductive.");
    my $rules = $c->list_rules;
    my $name = $rules->[0]{name};

    $c->mark_used($name);
    $c->mark_used($name);

    my $rule = $c->get_rule($name);
    is($rule->{use_count}, 2, 'use count incremented');
    ok(defined $rule->{last_used}, 'last_used set');
};

# === Test 10: Disabled crystallizer ===

subtest 'Disabled crystallizer does nothing' => sub {
    my $c = Clank::Crystallizer->new(store => Clank::Store->new(db => ':memory:'), enabled => 0);

    my $count = $c->crystallize(conversation => "Gold is gold.");
    is($count, 0, 'no rules when disabled');
};

# === Test 11: Empty conversation ===

subtest 'Empty conversation returns 0' => sub {
    my $c = Clank::Crystallizer->new(store => Clank::Store->new(db => ':memory:'));

    is($c->crystallize(conversation => ''), 0, 'empty string');
    is($c->crystallize(conversation => []), 0, 'empty array');
    is($c->crystallize(conversation => undef), 0, 'undef');
};

# === Test 12: Heuristic extraction patterns ===

subtest 'Heuristic extracts "X is Y" facts' => sub {
    my $c = Clank::Crystallizer->new(store => Clank::Store->new(db => ':memory:'));

    $c->crystallize(conversation => "Mercury is the smallest planet.");
    my $rules = $c->list_rules;
    ok(scalar @$rules > 0, 'rule extracted');
    like($rules->[0]{name}, qr/fact_/, 'fact rule name');
    is($rules->[0]{rule_type}, 'fact', 'rule type is fact');
};

subtest 'Heuristic extracts "if X then Y" rules' => sub {
    my $c = Clank::Crystallizer->new(store => Clank::Store->new(db => ':memory:'),
                                     min_confidence => 0.4);

    $c->crystallize(conversation => "If it rains then the ground gets wet.");
    my $rules = $c->list_rules;
    ok(scalar @$rules > 0, 'rule extracted');
    like($rules->[0]{name}, qr/(rule_|fact_)/, 'rule name has expected prefix');
};

# === Test 13: Rules engine integration ===

subtest 'Crystallized rules are registered in engine' => sub {
    my $store2 = Clank::Store->new(db => ':memory:');
    require Clank::Rules;
    my $engine = Clank::Rules->engine(store => $store2);

    my $c = Clank::Crystallizer->new(store => $store2, engine => $engine);
    $c->crystallize(conversation => "Gold is a precious metal.");

    my $rules = $engine->list;
    ok(scalar @$rules > 0, 'rule registered in engine');
};

# === Test 14: Bus integration ===

subtest 'Bus agent_end triggers crystallization' => sub {
    my $store3 = Clank::Store->new(db => ':memory:');
    require Clank::Bus;
    my $bus = Clank::Bus->new(store => $store3);
    require Clank::Wit::API;
    my $api = Clank::Wit::API->new(bus => $bus, store => $store3);

    my $c = Clank::Crystallizer->new(store => $store3);
    $c->register($api);

    my $sid = $store3->create_session(title => 'test');
    $store3->append_message(session_id => $sid, role => 'user', content => 'What is gold?');
    $store3->append_message(session_id => $sid, role => 'assistant', content => 'Gold is a precious metal.');

    $bus->publish('agent_end', { session_id => $sid });

    my $rules = $c->list_rules;
    ok(scalar @$rules > 0, 'crystallization triggered by bus event');
};

# === Test 15: Metrics integration ===

subtest 'Metrics tracking' => sub {
    my $store4 = Clank::Store->new(db => ':memory:');
    require Clank::Metrics;
    my $metrics = Clank::Metrics->new(store => $store4);

    my $c = Clank::Crystallizer->new(store => $store4, metrics => $metrics);
    $c->crystallize(conversation => "Silver is a conductor.");

    ok($metrics->get('crystallized') > 0, 'crystallized metric tracked');
};

done_testing();
