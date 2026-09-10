#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

use Clank::Store;
use Clank::Crystallizer;
use Clank::Util qw(now_ms);

# === Test 1: Schema migration adds new columns ===

subtest 'Schema has instinct columns' => sub {
    my $store = Clank::Store->new(db => ':memory:');
    my $c = Clank::Crystallizer->new(store => $store);

    my $cols = $store->dbh->selectall_arrayref("PRAGMA table_info(crystallized_rules)");
    my %col_names = map { $_->[1] => 1 } @$cols;

    ok($col_names{scope}, 'has scope column');
    ok($col_names{project_id}, 'has project_id column');
    ok($col_names{domain}, 'has domain column');
    ok($col_names{last_observed}, 'has last_observed column');
    ok($col_names{decay_rate}, 'has decay_rate column');
};

# === Test 2: Rules store with scope and project_id ===

subtest 'Store rule with scope and project' => sub {
    my $c = Clank::Crystallizer->new(store => Clank::Store->new(db => ':memory:'),
                                     project_id => 'abc123');

    # Use "X is Y" pattern so heuristic extraction produces a rule.
    my $count = $c->crystallize(
        conversation => "Perl is a programming language.",
        session_id => 'test-session', scope => 'global');
    ok($count > 0, 'rule stored');

    my $rules = $c->list_rules;
    is($rules->[0]{scope}, 'global', 'scope set');
    is($rules->[0]{project_id}, 'abc123', 'project_id set from constructor');
};

# === Test 3: Confidence decay ===

subtest 'Confidence decay reduces confidence' => sub {
    my $store = Clank::Store->new(db => ':memory:');
    my $c = Clank::Crystallizer->new(store => $store, decay_rate => 0.1);

    $c->crystallize(conversation => "Copper is conductive.");

    # Set confidence to 1.0 for predictable decay math.
    $store->dbh->do('UPDATE crystallized_rules SET confidence = 1.0');
    my $rules = $c->list_rules;
    my $name = $rules->[0]{name};

    # Simulate 2 weeks passing (last_used is now, so no decay yet).
    my $decayed = $c->apply_decay(now => now_ms());
    is($decayed, 0, 'no decay when recently used');

    # Manually set last_used to 2 weeks ago.
    my $two_weeks_ago = now_ms() - (14 * 24 * 60 * 60 * 1000);
    $store->dbh->do('UPDATE crystallized_rules SET last_used = ?', undef, $two_weeks_ago);

    $decayed = $c->apply_decay(now => now_ms(), rate => 0.1);
    is($decayed, 1, 'one rule decayed');

    my $rule = $c->get_rule($name);
    ok($rule->{confidence} < 1.0, 'confidence reduced');
    ok($rule->{confidence} > 0.75, 'confidence within expected range');
};

# === Test 4: Decay disables low-confidence rules ===

subtest 'Decay disables rules at zero confidence' => sub {
    my $store = Clank::Store->new(db => ':memory:');
    my $c = Clank::Crystallizer->new(store => $store);

    $c->crystallize(conversation => "Zinc is a metal.");

    # Set confidence to 0.5, decay_rate to 1.0, and last_used to 2 weeks ago.
    my $two_weeks_ago = now_ms() - (14 * 24 * 60 * 60 * 1000);
    $store->dbh->do('UPDATE crystallized_rules SET confidence = 0.5, decay_rate = 1.0, last_used = ?', undef, $two_weeks_ago);

    my $rules = $c->list_rules;
    my $name = $rules->[0]{name};

    my $decayed = $c->apply_decay(now => now_ms());
    is($decayed, 1, 'rule decayed to zero');

    my $active = $c->list_rules;
    my @found = grep { $_->{name} eq $name } @$active;
    is(scalar @found, 0, 'rule disabled after reaching zero confidence');
};

# === Test 5: Contradiction detection ===

subtest 'Contradiction reduces confidence' => sub {
    my $store = Clank::Store->new(db => ':memory:');
    my $c = Clank::Crystallizer->new(store => $store, min_confidence => 0.4);

    $c->crystallize(conversation => "If it rains then the ground gets wet.");
    my $rules = $c->list_rules;
    my $name = $rules->[0]{name};
    my $orig_conf = $rules->[0]{confidence};

    # Contradict with different action.
    my $result = $c->detect_contradiction({
        name => $name,
        action => 'the ground stays dry even when it rains',
    });

    ok(defined $result, 'contradiction detected');
    is($result->{old_confidence}, $orig_conf, 'old confidence recorded');
    ok($result->{new_confidence} < $orig_conf, 'confidence reduced');

    my $rule = $c->get_rule($name);
    is($rule->{confidence}, $result->{new_confidence}, 'new confidence persisted');
};

# === Test 6: Contradiction disables rule at zero ===

subtest 'Contradiction disables rule at zero confidence' => sub {
    my $store = Clank::Store->new(db => ':memory:');
    my $c = Clank::Crystallizer->new(store => $store, min_confidence => 0.4);

    $c->crystallize(conversation => "If it snows then it is cold.");

    # Set confidence to 0.05 so one contradiction kills it.
    $store->dbh->do('UPDATE crystallized_rules SET confidence = 0.05');

    my $result = $c->detect_contradiction({
        name => (values %{$store->dbh->selectall_hashref('SELECT name,confidence FROM crystallized_rules', 'name')})[0]{name} // 'x',
        action => 'it is warm when it snows',
    });

    ok(defined $result, 'contradiction detected');
    is($result->{new_confidence}, 0, 'confidence zeroed');
};

# === Test 7: Promotion from project to global ===

subtest 'Promote rules across projects' => sub {
    my $store = Clank::Store->new(db => ':memory:');
    my $c = Clank::Crystallizer->new(store => $store, min_confidence => 0.4);

    # Create same-named rule in two projects with high confidence.
    for my $proj ('proj_a', 'proj_b') {
        $store->dbh->do(
            "INSERT INTO crystallized_rules (name, rule_type, condition_def, action_def, confidence, source, scope, project_id, domain, created_at, last_observed) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            undef, 'fact_perl_strict', 'fact', '{}', '{}', 0.9, 'crystallized', 'project', $proj, 'general', now_ms(), now_ms());
    }

    my $promoted = $c->promote_rules(min_confidence => 0.8);
    is($promoted, 1, 'one rule promoted');

    my $globals = $store->dbh->selectall_arrayref(
        "SELECT COUNT(*) as cnt FROM crystallized_rules WHERE name = 'fact_perl_strict' AND scope = 'global'",
        { Slice => {} });
    is($globals->[0]{cnt}, 2, 'both rows promoted to global');
};

# === Test 8: Promotion requires 2+ projects ===

subtest 'Single-project rule not promoted' => sub {
    my $store = Clank::Store->new(db => ':memory:');
    my $c = Clank::Crystallizer->new(store => $store);

    $store->dbh->do(
        q{INSERT INTO crystallized_rules (name, rule_type, condition_def, action_def, confidence, source, scope, project_id, domain, created_at, last_observed)
          VALUES ('fact_perl_only', 'fact', '{}', '{}', 0.95, 'crystallized', 'project', 'proj_a', 'general', ?, ?)},
        undef, now_ms(), now_ms());

    my $promoted = $c->promote_rules;
    is($promoted, 0, 'no promotion for single project');
};

# === Test 9: Observe updates last_observed ===

subtest 'Observe updates matching rules' => sub {
    my $store = Clank::Store->new(db => ':memory:');
    my $c = Clank::Crystallizer->new(store => $store, project_id => 'test_proj');

    # Create a rule that will contain 'bash' in its text.
    $store->dbh->do(
        q{INSERT INTO crystallized_rules (name, rule_type, condition_def, action_def, confidence, source, scope, project_id, domain, created_at, last_observed)
          VALUES ('fact_bash_terminal', 'fact', 'bash', 'use bash for terminal', 0.8, 'crystallized', 'global', 'test_proj', 'general', ?, ?)},
        undef, now_ms(), now_ms());

    my $observed = $c->observe(tool => 'bash', domain => 'testing');
    ok($observed > 0, 'observed matching rules');

    my $rules = $c->list_rules;
    my @bash = grep { $_->{name} eq 'fact_bash_terminal' } @$rules;
    ok($bash[0]{last_observed} > 0, 'last_observed set');
};

# === Test 10: Project detection ===

subtest 'Detect project ID from git' => sub {
    my $project_id = Clank::Crystallizer->detect_project_id(path => '/home/clam/dev/Clank');
    ok(defined $project_id, 'detected project ID');
    like($project_id, qr/^[0-9a-f]{8}$/, 'project ID is 8-char hex');
};

# === Test 11: list_instincts filtering ===

subtest 'List instincts by scope and domain' => sub {
    my $store = Clank::Store->new(db => ':memory:');
    my $c = Clank::Crystallizer->new(store => $store);

    $store->dbh->do(
        q{INSERT INTO crystallized_rules (name, rule_type, condition_def, action_def, confidence, source, scope, domain, created_at, last_observed)
          VALUES ('rule_a', 'pattern', '{}', '{}', 0.8, 'crystallized', 'project', 'testing', ?, ?)},
        undef, now_ms(), now_ms());
    $store->dbh->do(
        q{INSERT INTO crystallized_rules (name, rule_type, condition_def, action_def, confidence, source, scope, domain, created_at, last_observed)
          VALUES ('rule_b', 'pattern', '{}', '{}', 0.7, 'crystallized', 'global', 'git', ?, ?)},
        undef, now_ms(), now_ms());

    my $project = $c->list_instincts(scope => 'project');
    is(scalar @$project, 1, 'one project-scoped rule');
    is($project->[0]{name}, 'rule_a', 'correct rule');

    my $testing = $c->list_instincts(domain => 'testing');
    is(scalar @$testing, 1, 'one testing-domain rule');

    my $all = $c->list_instincts;
    is(scalar @$all, 2, 'all rules returned');
};

# === Test 12: Stats include instinct fields ===

subtest 'Stats has instinct fields' => sub {
    my $c = Clank::Crystallizer->new(store => Clank::Store->new(db => ':memory:'));

    $c->crystallize(conversation => "Gold is gold.");
    my $s = $c->stats;
    ok(exists $s->{project_scoped}, 'has project_scoped');
    ok(exists $s->{global_rules}, 'has global_rules');
    is($s->{project_scoped}, 0, 'no project-scoped by default');
    is($s->{global_rules}, 1, 'one global rule');
};

# === Test 13: CLI instinct status ===

subtest 'CLI instinct status' => sub {
    require Clank::Bus;
    require Clank::Wit::API;
    my $store = Clank::Store->new(db => ':memory:');
    my $bus = Clank::Bus->new(store => $store);
    my $api = Clank::Wit::API->new(bus => $bus, store => $store);

    my $c = Clank::Crystallizer->new(store => $store);
    $c->register($api);
    $c->crystallize(conversation => "Silver is shiny.");

    my $output = $c->_cmd_instinct(undef, 'status');
    like($output, qr/total rules: 1/, 'status shows rule count');
    like($output, qr/active: 1/, 'status shows active count');
};

# === Test 14: Decay via CLI ===

subtest 'CLI instinct decay' => sub {
    my $store = Clank::Store->new(db => ':memory:');
    my $c = Clank::Crystallizer->new(store => $store);

    my $output = $c->_cmd_instinct(undef, 'decay');
    like($output, qr/Decay applied/, 'decay command works');
};

# === Test 15: Bus observation hook ===

subtest 'Bus observation hook triggers observe' => sub {
    my $store = Clank::Store->new(db => ':memory:');
    require Clank::Bus;
    my $bus = Clank::Bus->new(store => $store);
    require Clank::Wit::API;
    my $api = Clank::Wit::API->new(bus => $bus, store => $store);

    my $c = Clank::Crystallizer->new(store => $store);
    $c->register($api);

    # Create a rule containing 'bash' so observe can match it.
    $store->dbh->do(
        q{INSERT INTO crystallized_rules (name, rule_type, condition_def, action_def, confidence, source, scope, domain, created_at, last_observed)
          VALUES ('fact_bash_use', 'fact', 'bash', 'run bash commands', 0.8, 'crystallized', 'global', 'terminal', ?, ?)},
        undef, now_ms(), now_ms());

    $bus->publish('observation', { tool => 'bash', domain => 'terminal' });

    my $rule = $c->get_rule('fact_bash_use');
    ok($rule->{last_observed} > 0, 'observation updated last_observed');
};

done_testing();
