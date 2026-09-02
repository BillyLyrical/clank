# Logic deck wit layer: datalog.query tool + task.query_logic bus agent,
# rule.add/rule.run shared-registry tools + task.classify bus agent, and the
# rules-first input classifier (policy layer) verified end-to-end through a
# real session.  The registry lives in kv under 'rules.dsl' — shared by every
# agent on the same DB (facts are state; these rules are knowledge).
use strict; use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::RealBin/../lib";
use File::Temp qw(tempdir);
use JSON::PP;
use Clam::Store;
use Clam::Bus;
use Clam::Session;
use Clam::PluginManager;
use Clam::Driver;
use Clam::Util qw(jdecode jencode);

my $DECKS = "$FindBin::RealBin/../decks";
my $tmp   = tempdir(CLEANUP => 1);
local $ENV{HOME} = "$tmp/home";
delete $ENV{CLAM_WITS_PATH};
chdir $tmp or die "chdir: $!";

# ===========================================================================
# 1. Load the logic deck; new tools present
# ===========================================================================
my $store = Clam::Store->new(path => ":memory:");
my $bus   = Clam::Bus->new(store => $store);
my $sess  = Clam::Session->new(store => $store, bus => $bus);
my $pm    = Clam::PluginManager->new;
$pm->bind(bus => $bus, store => $store, session => $sess);

my @wits = $pm->load_all(extra_paths => ["$DECKS/logic"]);
is(scalar(@wits), 1, 'logic deck loaded');
is_deeply($pm->errors, [], 'no load errors in logic deck');

my %tools = map { $_->{name} => $_ } $pm->all_tools();
for my $t (qw(datalog.query rule.add rule.run rule.classify_input)) {
    ok($tools{$t}, "tool present: $t");
}

sub out_json { jdecode($_[0]->{output}) }

# ===========================================================================
# 2. datalog.query — tool behavior
# ===========================================================================
my $r = $tools{'datalog.query'}->run({
    program => 'parent(alice,bob). parent(bob,carol). gp(X,Y) :- parent(X,Z), parent(Z,Y).',
    goal    => 'gp(alice, Y)',
});
is($r->{isError}, 0, 'datalog.query runs');
my $sol = out_json($r);
is($sol->{ok}, 1, 'datalog: ok');
is_deeply([ map { $_->{Y} } @{ $sol->{solutions} } ], ['carol'], 'datalog: grandparent solution');

# facts param appends fact lines to the program
$r = $tools{'datalog.query'}->run({ goal => 'likes(bob, pizza)', facts => [ 'likes(bob, pizza)' ] });
is((out_json($r))->{ok}, 1, 'datalog: facts param works');

# trailing dot on a string goal is tolerated (the facade adds it)
$r = $tools{'datalog.query'}->run({ program => 'p(a).', goal => 'p(X).' });
is_deeply([ map { $_->{X} } @{ (out_json($r))->{solutions} } ], ['a'], 'datalog: trailing dot tolerated');

# bad program -> structured error, not a crash
$r = $tools{'datalog.query'}->run({ program => 'parent(alice,', goal => 'p(X)' });
is((out_json($r))->{ok}, 0, 'datalog: bad program -> ok=0');
like((out_json($r))->{error}, qr/parse error/, 'datalog: parse error reported');

# missing goal
$r = $tools{'datalog.query'}->run({ program => 'p(a).' });
is((out_json($r))->{ok}, 0, 'datalog: missing goal -> ok=0');

# ===========================================================================
# 3. task.query_logic bus agent -> result.query_logic (DESIGN section 8)
# ===========================================================================
$bus->publish('task.query_logic', {
    program => 'parent(alice,bob). parent(bob,carol). gp(X,Y) :- parent(X,Z), parent(Z,Y).',
    goal    => 'gp(alice, Y)',
});
my @ev = @{ $store->query_events(topic => 'result.query_logic') };
is(scalar @ev, 1, 'task.query_logic produced a result.query_logic event');
is_deeply([ map { $_->{Y} } @{ $ev[0]{payload}{solutions} } ], ['carol'], 'bus agent returned the solution');

# ===========================================================================
# 4. rule.add — shared registry (kv key rules.dsl)
# ===========================================================================
$r = $tools{'rule.run'}->run({ text => 'fix the parser' });
is((out_json($r))->{matched}, 0, 'rule.run: empty registry -> no match');

$r = $tools{'rule.add'}->run({ name => 'classify_fix', when => '/^(?:fix|bug)/', then => ['domain debug', 'mode debug'] });
my $add1 = out_json($r);
is($add1->{ok}, 1, 'rule.add: structured fields accepted');
is($add1->{rule}, 'classify_fix', 'rule.add: reports rule name');
is($add1->{total_rules}, 1, 'rule.add: registry count is 1');

# raw DSL variant (two rules in one call)
$r = $tools{'rule.add'}->run({ dsl => "rule greet\n  when /hello/i\n  then output hi there\nend\nrule build\n  when /^(?:make|build)/\n  then domain build\nend\n" });
is((out_json($r))->{total_rules}, 3, 'rule.add: raw DSL appends (now 3 rules)');

# invalid input rejected without persisting
my $reglen = length(($store->kv_get('rules.dsl') // { dsl => '' })->{dsl});
$r = $tools{'rule.add'}->run({ name => 'x' });   # missing when
is((out_json($r))->{ok}, 0, 'rule.add: missing when -> ok=0');
$r = $tools{'rule.add'}->run({ dsl => "not a rule at all" });
is((out_json($r))->{ok}, 0, 'rule.add: zero-rule DSL rejected');
is(length(($store->kv_get('rules.dsl') // { dsl => '' })->{dsl}), $reglen, 'rejected rules not persisted');

# ===========================================================================
# 5. rule.run — classification over the registry
# ===========================================================================
$r = $tools{'rule.run'}->run({ text => 'fix the parser' });
my $m = out_json($r);
is($m->{matched}, 1, 'rule.run: match found');
is($m->{rule}, 'classify_fix', 'rule.run: reports which rule fired');
is($m->{result}{domain}, 'debug', 'rule.run: classification result carried through');
ok(($m->{confidence} // 0) > 0, 'rule.run: confidence reported');

$r = $tools{'rule.run'}->run({ text => 'hello there' });
is((out_json($r))->{result}{output}, 'hi there', 'rule.run: output action result');

# strategy all + inline DSL: every matching rule runs
$r = $tools{'rule.run'}->run({
    text     => 'fix the parser',
    strategy => 'all',
    dsl      => "rule urgent\n  when /parser|\bbug\b/i\n  then tag urgent\nend\n",
});
my @mm = @{ (out_json($r))->{matches} };
is(scalar(@mm), 2, 'rule.run all: two matches');
ok((grep { $_->{rule} eq 'classify_fix' } @mm), 'rule.run all: includes registry rule');
ok((grep { $_->{rule} eq 'urgent' && $_->{result}{tags}[0] eq 'urgent' } @mm), 'rule.run all: includes inline rule with its result');

# inline DSL alone (registry rules may not match)
$r = $tools{'rule.run'}->run({ text => 'deploy to prod', dsl => "rule deploy\n  when /deploy/\n  then domain ops\nend\n" });
is((out_json($r))->{result}{domain}, 'ops', 'rule.run: inline DSL works');

# ===========================================================================
# 6. task.classify bus agent -> result.classified
# ===========================================================================
$bus->publish('task.classify', { text => 'fix the parser' });
my @ce = @{ $store->query_events(topic => 'result.classified') };
is(scalar @ce, 1, 'task.classify produced a result.classified event');
is($ce[0]{payload}{rule}, 'classify_fix', 'bus classification names the rule');

# ===========================================================================
# 7. classify_input — rules-first policy layer through a real session
# ===========================================================================
package ScriptedProvider;
sub new { my ($c, $script) = @_; return bless { script => $script, calls => [] }, $c }
sub chat_payload { my ($s, %a) = @_; return { model => 'mock', messages => $a{messages}, tools => $a{tools} } }
sub post_json {
    my ($s, $path, $payload) = @_;
    push @{ $s->{calls} }, $payload;
    return $s->{script}->($payload, scalar @{ $s->{calls} });
}

package main;

my $answer = sub {
    return { choices => [ { finish_reason => 'stop', message => { content => 'answered' } } ] };
};

# 7a. Inert with an empty registry: no annotation, model still called
my $d1 = Clam::Driver->new(provider => ScriptedProvider->new($answer), db => ':memory:', wit_paths => ["$DECKS/logic"]);
$d1->start;
my $r1 = $d1->ask('fix the parser');
is($r1->{ok}, 1, 'inert: ask ok with empty registry');
is($r1->{handled} // 0, 0, 'inert: never handled (transform-only policy)');
my ($user1) = grep { $_->{role} eq 'user' } @{ $d1->messages() };
unlike($user1->{content}, qr/\[rules:/, 'inert: prompt not annotated without rules');
$d1->close;

# 7b. With a rule in the registry: prompt annotated + input.classified journaled
my $prov2 = ScriptedProvider->new($answer);
my $d2 = Clam::Driver->new(provider => $prov2, db => ':memory:', wit_paths => ["$DECKS/logic"]);
$d2->start;
$d2->store->kv_set('rules.dsl', { dsl => "rule classify_fix\n  when /^(?:fix|bug)/\n  then domain debug\nend\n" });

my $r2 = $d2->ask('fix the parser');
is($r2->{ok}, 1, 'annotated: ask ok');
my ($user2) = grep { $_->{role} eq 'user' } @{ $d2->messages() };
like($user2->{content}, qr/^\[rules: rule=classify_fix domain=debug\] fix the parser$/, 'annotated: prompt carries classification tag');

# The model saw the annotated text (provider payload check)
my ($payload1) = @{ $prov2->{calls} };
ok((grep { defined $_->{content} && !ref $_->{content} && $_->{content} =~ /\[rules: rule=classify_fix/ } @{ $payload1->{messages} }), 'annotated: model received the tagged prompt');

# input.classified event journaled with the classification
my @ie = @{ $d2->store->query_events(topic => 'input.classified') };
is(scalar @ie, 1, 'annotated: input.classified journaled');
is($ie[0]{payload}{rule}, 'classify_fix', 'annotated: event carries rule name');

# Non-matching text passes through unannotated
my $r3 = $d2->ask('tell me a joke');
my @users3 = grep { $_->{role} eq 'user' } @{ $d2->messages() };
unlike($users3[-1]{content}, qr/\[rules:/, 'annotated: non-matching input untouched');
$d2->close;

done_testing();
