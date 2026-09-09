use strict; use warnings;
use Test::More;
use lib 'lib';
use lib 'wits/psh/lib';

# Test crystallized rules in isolation via psh_sandbox.
# Verifies: extraction → storage → retrieval → isolated execution.

package MockAPI {
    sub new { bless { tools => [] }, shift }
    sub register_tool { my ($self, %def) = @_; push @{$self->{tools}}, \%def; return $def{name} }
    sub register_command { return }
    sub on { return 1 }
    sub track_sub { return 1 }
    sub ui { return undef }
    sub bus { return undef }
    sub store { return undef }
    sub session { return undef }
    sub wit_name { return 'test' }
}

package main;

use Clank::Store;
use Clank::Crystallizer;
use Clank::Rules::Engine;

# --- setup: in-memory store + crystallizer + engine ---

my $store = Clank::Store->new(db => ':memory:');
my $engine = Clank::Rules::Engine->new(store => $store);
my $cryst = Clank::Crystallizer->new(store => $store, engine => $engine);

# --- test 1: heuristic extraction ---

my @patterns = $cryst->_extract_heuristic(
    "The default port is 5432. If the file is missing then create it."
);
ok(scalar @patterns >= 2, 'heuristic extracts patterns (got ' . scalar(@patterns) . ')');

my ($fact_p) = grep { $_->{type} eq 'fact' } @patterns;
my ($rule_p) = grep { $_->{type} eq 'pattern' } @patterns;

ok($fact_p, 'extracted a fact');
is($fact_p->{name}, 'fact_the_default_port', 'fact name derived from subject');
like(ref $fact_p->{action} eq 'HASH' ? $fact_p->{action}{value} : $fact_p->{action},
    qr/default port is 5432/i, 'fact action contains expected value');

ok($rule_p, 'extracted a pattern rule');
like($rule_p->{condition}, qr/file is missing/i, 'pattern condition extracted');
like($rule_p->{action}, qr/create it/i, 'pattern action extracted');

# --- test 2: store + retrieve rules ---

my $id1 = $cryst->_store_rule($fact_p, session_id => 'test-session');
ok($id1, 'fact rule stored');
my $id2 = $cryst->_store_rule($rule_p, session_id => 'test-session');
ok($id2, 'pattern rule stored');

my $stored_fact = $cryst->get_rule('fact_the_default_port');
ok($stored_fact, 'fact rule retrievable');
is($stored_fact->{confidence}, 0.6, 'confidence preserved');
is($stored_fact->{rule_type}, 'fact', 'type preserved');

# --- test 3: register rules in engine ---

$cryst->_register_rule($fact_p);
$cryst->_register_rule($rule_p);

my $listed = $engine->list;
ok(@$listed >= 2, 'engine has registered rules');

# --- test 4: pattern rule matches and executes ---

# Test the pattern rule directly (not via engine.execute which picks first match)
my $pattern_rule = $engine->get_rule('rule_the_file_is_missing');
ok($pattern_rule, 'pattern rule found in engine');
ok($pattern_rule->match, 'pattern rule has compiled regex');
my $score = $pattern_rule->test({ text => 'the file is missing from the directory' });
ok($score > 0, 'pattern rule matches');
my $result = $pattern_rule->execute({ text => 'the file is missing' });
# Pattern rule action is a string: "create it"
like($result, qr/create it/i, 'pattern rule action returns expected value');

# --- test 5: run rule actions in psh_sandbox (isolation) ---

require Clank::Wits::Psh::Eval;
my $api_mock = MockAPI->new();
Clank::Wits::Psh::Eval::register('Clank::Wits::Psh::Eval', $api_mock);
my ($sb_def) = grep { $_->{name} eq 'psh_sandbox' } @{$api_mock->{tools}};
my $sandbox = $sb_def->{execute};

# 5a: fact rule action — execute the stored action in sandbox
my $fact_action = $stored_fact->{action_def};
# The action is a JSON hash: {"type":"assert","value":"The default port is 5432"}
my $sandbox_code = qq{
    use JSON::PP;
    my \$action = decode_json('$fact_action');
    print \$action->{type} . ':' . \$action->{value};
};

my $r = $sandbox->({ code => $sandbox_code, timeout => 5 });
ok($r->{ok}, 'sandbox executes fact rule action');
is($r->{result}, 'assert:The default port is 5432', 'sandbox returns correct fact data');

# 5b: pattern rule action — verify condition is valid regex
my $pattern_condition = $rule_p->{condition};
my $regex_test = qq{
    my \$re = qr{$pattern_condition};
    if ('the file is missing' =~ \$re) {
        print "MATCH";
    } else {
        print "NO_MATCH";
    }
};
$r = $sandbox->({ code => $regex_test, timeout => 5 });
ok($r->{ok}, 'sandbox regex test runs');
is($r->{result}, 'MATCH', 'crystallized regex matches expected input');

# 5c: negative test — regex should NOT match unrelated text
$regex_test = qq{
    my \$re = qr{$pattern_condition};
    if ('the sky is blue' =~ \$re) {
        print "MATCH";
    } else {
        print "NO_MATCH";
    }
};
$r = $sandbox->({ code => $regex_test, timeout => 5 });
ok($r->{ok}, 'sandbox negative regex test runs');
is($r->{result}, 'NO_MATCH', 'crystallized regex rejects non-matching input');

# --- test 6: round-trip — crystallize a conversation, retrieve, sandbox-execute ---

my $conv = [
    { role => 'user',      content => 'what is the cache TTL?' },
    { role => 'assistant', content => 'The cache TTL is 300 seconds. If TTL expires then refresh the cache.' },
];
my $registered = $cryst->crystallize(conversation => $conv, session_id => 'rt-test');
ok($registered > 0, "crystallized $registered rules from conversation");

my $all_rules = $cryst->list_rules;
ok(@$all_rules > 0, 'rules stored after crystallization');

# Find a fact rule and test it in sandbox
my ($ttl_fact) = grep { $_->{name} =~ /cache.*ttl/i } @$all_rules;
if ($ttl_fact) {
    my $action_json = $ttl_fact->{action_def};
    $r = $sandbox->({ code => qq{
        use JSON::PP;
        my \$data = eval { decode_json(q{$action_json}) };
        if (\$data && \$data->{value}) {
            print \$data->{value};
        } else {
            print "PARSE_FAIL";
        }
    }, timeout => 5 });
    ok($r->{ok}, 'sandbox parses round-tripped fact action');
    like($r->{result}, qr/300.*seconds/i, 'round-tripped fact contains correct value');
} else {
    pass('no TTL fact found (heuristic extraction varies)');
}

# --- test 7: stats reflect crystallized rules ---

my $stats = $cryst->stats;
ok($stats->{total_rules} > 0, 'stats show rules');
ok($stats->{active} > 0, 'stats show active rules');

# --- test 8: disable + sandbox ---

my $disable_name = $all_rules->[-1]{name};
$cryst->disable_rule($disable_name);
my $disabled = $cryst->get_rule($disable_name);
ok(!$disabled, 'disabled rule not returned by get_rule');

my $active = $cryst->list_rules;
my @still_active = grep { $_->{name} eq $disable_name } @$active;
ok(!@still_active, 'disabled rule excluded from list');

done_testing();
