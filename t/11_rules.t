# Clam::Rules: rule engine ported from clam-old (Clam::Rule/RuleEngine/DSL/
# Parser/DecisionTree/FSM/BehaviorTree). Facts live in the shared SQLite store
# — the blackboard every agent on this DB reads and writes. Porting fixes
# covered here: DSL closure capture, DecisionTree named-rule lookup, FSM
# events() undef deref, rules_fired counting only productive firings.
use strict; use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::RealBin/../lib";   # absolute: test chdirs later
use File::Temp qw(tempdir);
use Clam::Store;
use Clam::Rules;
use Clam::Rules::Rule;
use Clam::Rules::Engine;
use Clam::Rules::DSL;
use Clam::Rules::Parser;
use Clam::Rules::DecisionTree;
use Clam::Rules::FSM;
use Clam::Rules::BehaviorTree;

my $tmp = tempdir(CLEANUP => 1);

# ===========================================================================
# 1. Rule: pattern / fuzzy / guard / disabled
# ===========================================================================
{
    my $r = Clam::Rules::Rule->new(name=>'auth', type=>'pattern', match=>qr/\b(?:jwt|token)\b/i, action=>sub { { domain => 'auth' } });
    is($r->test({ text => 'add JWT validation' }), 1.0, 'pattern: regex matches -> weight');
    is($r->test({ text => 'nothing here' }), 0, 'pattern: no match -> 0');

    my $w = Clam::Rules::Rule->new(name=>'w', type=>'pattern', match=>qr/x/, weight=>0.5);
    is($w->test({ text => 'x' }), 0.5, 'pattern: score scaled by weight');

    my $g = Clam::Rules::Rule->new(name=>'g', type=>'pattern', match=>qr/fix/, guard=>sub { $_[0]{file} eq 'a.pl' });
    is($g->test({ text => 'fix it', file => 'a.pl' }), 1.0, 'guard passes -> rule tests');
    is($g->test({ text => 'fix it', file => 'b.pm' }), 0, 'guard fails -> 0 without testing pattern');

    my $d = Clam::Rules::Rule->new(name=>'d', type=>'pattern', match=>qr/x/, enabled=>0);
    is($d->test({ text => 'x' }), 0, 'disabled rule never matches');

    # fuzzy: exact (case-insensitive) = weight
    my $f1 = Clam::Rules::Rule->new(name=>'f1', type=>'fuzzy', match=>'Hello World');
    is($f1->test({ text => 'hello world' }), 1.0, 'fuzzy: case-insensitive exact -> 1.0');

    # fuzzy: word overlap (Jaccard) — "the quick brown fox" vs "quick fox":
    # inter=2 union=4 -> 0.5*0.7 = 0.35, no substring bonus
    my $f2 = Clam::Rules::Rule->new(name=>'f2', type=>'fuzzy', match=>'quick fox');
    ok(abs($f2->test({ text => 'the quick brown fox' }) - 0.35) < 1e-9, 'fuzzy: Jaccard overlap score');

    # fuzzy: substring bonus — "hello world" vs "world": (0.5*0.7) + (0.3*0.3) = 0.44
    my $f3 = Clam::Rules::Rule->new(name=>'f3', type=>'fuzzy', match=>'world');
    ok(abs($f3->test({ text => 'hello world' }) - 0.44) < 1e-9, 'fuzzy: substring bonus');

    # fuzzy: weight scales the score
    my $f4 = Clam::Rules::Rule->new(name=>'f4', type=>'fuzzy', match=>'world', weight=>0.5);
    ok(abs($f4->test({ text => 'hello world' }) - 0.22) < 1e-9, 'fuzzy: score * weight');

    is_deeply($r->execute({}), { domain => 'auth' }, 'execute runs the action closure');
    my $noact = Clam::Rules::Rule->new(name=>'na', type=>'pattern', match=>qr/x/);
    is($noact->execute({ text => 'x' }), undef, 'execute without action -> undef');
}

# ===========================================================================
# 2. Store facts: CRUD + persistence across connections (one format)
# ===========================================================================
{
    my $db = "$tmp/facts.db";
    my $s  = Clam::Store->new(path => $db);

    my $id1 = $s->assert_fact('human', { name => 'socrates' });
    ok($id1 && length $id1, 'assert_fact returns an id');
    is($s->fact_count('human'), 1, 'fact_count by type');
    $s->assert_fact('mortal', { name => 'plato' }, { asserted_by => 'test' });
    is($s->fact_count(), 2, 'fact_count all types');

    my @humans = @{ $s->query_facts('human') };
    is(scalar @humans, 1, 'query_facts filters by type');
    is_deeply($humans[0]{attributes}, { name => 'socrates' }, 'attributes decoded to hashref');
    is($humans[0]{asserted_by}, 'external', 'default asserted_by is external');
    my @mortals = @{ $s->query_facts('mortal') };
    is($mortals[0]{asserted_by}, 'test', 'custom asserted_by stored');

    # persistence: a fresh connection to the same file sees everything
    my $s2 = Clam::Store->new(path => $db);
    is($s2->fact_count(), 2, 'facts persist across connections (shared blackboard)');

    $s2->retract_fact($id1);
    is($s2->fact_count('human'), 0, 'retract_fact removes the row');
    is($s->fact_count('human'), 0, 'retraction visible to other connection');

    $s2->clear_facts;
    is($s2->fact_count(), 0, 'clear_facts empties the store');
}
# ===========================================================================
# 3. Engine: SQLite-backed working set + execution strategies
# ===========================================================================
{
    eval { Clam::Rules::Engine->new() };
    like($@, qr/requires a store/, 'engine requires a store');

    my $db = "$tmp/engine.db";
    my $s1 = Clam::Store->new(path => $db);
    my $e  = Clam::Rules::Engine->new(store => $s1, strategy => 'first');

    # engine writes go through to the store (visible to a fresh connection)
    $e->assert_fact('human', { name => 'socrates' });
    is(Clam::Store->new(path => $db)->fact_count('human'), 1, 'engine assert_fact persists to store');

    # a fresh engine on the same DB loads existing facts into its working set
    my $e2 = Clam::Rules::Engine->new(store => Clam::Store->new(path => $db));
    is($e2->fact_count(), 1, 'fresh engine loads shared facts from store');
    is(scalar @{ $e2->query_facts('human') }, 1, 'working set query by type');

    # retract/clear sync both sides
    my ($fid) = map { $_->{id} } @{ $e2->all_facts };
    $e2->retract_fact($fid);
    is(Clam::Store->new(path => $db)->fact_count(), 0, 'engine retract_fact persists');

    # rule registry: priority order, remove, get_rule, load
    $e->add(Clam::Rules::Rule->new(name=>'low',  type=>'pattern', priority=>1, match=>qr/./));
    $e->add(Clam::Rules::Rule->new(name=>'high', type=>'pattern', priority=>9, match=>qr/./));
    is([ map { $_->{name} } @{ $e->list } ]->[0], 'high', 'rules kept in priority order');
    is($e->get_rule('low')->priority, 1, 'get_rule finds by name');
    is($e->get_rule('nope'), undef, 'get_rule unknown -> undef');
    $e->remove('low');
    is(scalar @{ $e->list }, 1, 'remove drops the rule');
    $e->load([{ name => 'loaded', type => 'pattern', match => qr/x/ }]);
    ok($e->get_rule('loaded'), 'load() builds rules from configs');

    # strategies
    my $s3 = Clam::Store->new(path => ':memory:');
    my $ef = Clam::Rules::Engine->new(store => $s3, strategy => 'first');
    $ef->add(Clam::Rules::Rule->new(name=>'a', type=>'pattern', priority=>10, match=>qr/fix/, action=>sub { { r => 'a' } }));
    $ef->add(Clam::Rules::Rule->new(name=>'b', type=>'pattern', priority=>5,  match=>qr/fix/, action=>sub { { r => 'b' } }));
    is($ef->execute({ text => 'fix it' })->{r}, 'a', 'strategy first: highest priority wins');

    $ef->set_strategy('all');
    my @res = @{ $ef->execute({ text => 'fix it' }) };
    is(scalar @res, 2, 'strategy all: every match runs');
    ok(exists $res[0]{_confidence} && exists $res[0]{_rule}, 'all results carry _confidence/_rule');

    my $ep = Clam::Rules::Engine->new(store => $s3, strategy => 'probabilistic');
    $ep->add(Clam::Rules::Rule->new(name=>'p', type=>'pattern', match=>qr/x/, weight=>0.8, action=>sub { { r => 'p' } }));
    my $pr = $ep->execute({ text => 'x' });
    is($pr->{r}, 'p', 'probabilistic: single match returns its result');
    ok(abs($pr->{_confidence} - 0.8) < 1e-9, 'probabilistic: _confidence = score');

    my $er = Clam::Rules::Engine->new(store => $s3, strategy => 'random');
    $er->add(Clam::Rules::Rule->new(name=>'q', type=>'pattern', match=>qr/x/, action=>sub { { r => 'q' } }));
    is($er->execute({ text => 'x' })->{r}, 'q', 'strategy random: single match');

    my $en = Clam::Rules::Engine->new(store => $s3);
    is($en->execute({ text => 'nothing matches' }), undef, 'no match -> undef');
    is($ef->find({ text => 'zzz' }), undef, 'find: no match -> undef');
    is(scalar @{ $ef->find_all({ text => 'fix it' }) }, 2, 'find_all returns all matches');
}

# ===========================================================================
# 4. Forward chaining: production rules over the shared fact store
# ===========================================================================
{
    my $s = Clam::Store->new(path => ':memory:');
    my $e = Clam::Rules::Engine->new(store => $s);

    # multi-step chain: a -> b -> c (r1 higher priority, so r2 sees fresh b in iter 1)
    $e->add(Clam::Rules::Rule->new(name=>'a_to_b', type=>'production', priority=>10,
        conditions => [{ type => 'a' }], action => sub { { type => 'b' } }));
    $e->add(Clam::Rules::Rule->new(name=>'b_to_c', type=>'production', priority=>5,
        conditions => [{ type => 'b' }], action => sub { { type => 'c' } }));

    my $res = $e->chain([{ type => 'a' }]);
    is($res->{iterations}, 1, 'chain: fixpoint reached in one iteration');
    is($res->{facts_asserted}, 3, 'chain: initial + two derived facts');
    is($res->{rules_fired}, 2, 'chain: only productive firings counted');
    ok(!$res->{max_reached}, 'chain: depth limit not hit');
    is($e->fact_count('c'), 1, 'derived fact c asserted into store');

    # the action sees the matched fact via context
    my $s2 = Clam::Store->new(path => ':memory:');
    my $e2 = Clam::Rules::Engine->new(store => $s2);
    $e2->assert_fact('x', { v => 5, name => 'abc' });
    $e2->add(Clam::Rules::Rule->new(name=>'echo', type=>'production',
        conditions => [{ type => 'x' }],
        action => sub { my ($c) = @_; return { type => 'echoed', attributes => { v => $c->{match}{attributes}{v} } }; }));
    $e2->chain([]);
    is_deeply($e2->query_facts('echoed')->[0]{attributes}, { v => 5 }, 'action receives matched fact');

    # condition operators: eq ne gt lt regex exists (+ one that must not fire)
    my $s3 = Clam::Store->new(path => ':memory:');
    my $e3 = Clam::Rules::Engine->new(store => $s3);
    $e3->assert_fact('x',  { v => 5, name => 'abc' });
    $e3->assert_fact('x2', {});
    $e3->assert_fact('x3', { name => 'n', v => 1 });
    my @ops = (
        ['op_eq',     { type=>'x',  v=>5,          op=>'eq'     }],
        ['op_ne',     { type=>'x',  v=>9,          op=>'ne'     }],
        ['op_gt',     { type=>'x',  v=>3,          op=>'gt'     }],
        ['op_lt',     { type=>'x',  v=>10,         op=>'lt'     }],
        ['op_regex',  { type=>'x',  name=>'^a.*c$', op=>'regex' }],
        ['op_exists', { type=>'x3', v=>99,         op=>'exists' }],
    );
    for my $op (@ops) {
        $e3->add(Clam::Rules::Rule->new(name=>$op->[0], type=>'production',
            conditions => [ $op->[1] ], action => sub { { type => $op->[0] } }));
    }
    $e3->add(Clam::Rules::Rule->new(name=>'op_noexist', type=>'production',
        conditions => [{ type=>'x2', name=>1, op=>'exists' }], action => sub { { type => 'op_noexist' } }));
    $e3->chain([]);
    for my $op (@ops) { is($e3->fact_count($op->[0]), 1, "condition operator: $op->[1]{op}"); }
    is($e3->fact_count('op_noexist'), 0, 'exists on missing key does not fire');

    # max_chain_depth guard: a rule that always produces a new fact
    my $s4 = Clam::Store->new(path => ':memory:');
    my $e4 = Clam::Rules::Engine->new(store => $s4, max_chain_depth => 5);
    $e4->assert_fact('seed', {});
    $e4->add(Clam::Rules::Rule->new(name=>'ticker', type=>'production',
        conditions => [{ type => 'seed' }],
        action => sub { my ($c) = @_; return { type => 'tick', attributes => { n => scalar @{ $c->{facts}{tick} // [] } } }; }));
    my $r4 = $e4->chain([]);
    is($r4->{iterations}, 5, 'depth limit stops the chain');
    ok($r4->{max_reached}, 'max_reached flagged');
    is($e4->fact_count('tick'), 5, 'exactly max_chain_depth new facts');
}
# ===========================================================================
# 5. DSL: compile "when/then" text to rules (incl. closure-capture regression)
# ===========================================================================
{
    my $rules = Clam::Rules->parse(<<'D');
rule classify_fix priority 20 domain debug
    when /^(?:fix|bug|error)/
    then mode debug
end
rule greet priority 5
    when /hello/i
    then output hi there
    then tag greeting
end
D
    is(scalar @$rules, 2, 'DSL: two rules parsed');
    is($rules->[0]->name, 'classify_fix', 'DSL: rule name');
    is($rules->[0]->priority, 20, 'DSL: priority from header');

    my $r1 = $rules->[0]->execute({ text => 'fix the parser' });
    is($r1->{domain}, 'debug', 'DSL: domain applied (closure capture fix)');
    is($r1->{mode}, 'debug', 'DSL: then-mode action applied after parse completes');

    my $r2 = $rules->[1]->execute({ text => 'HELLO world' });
    is($r2->{output}, 'hi there', 'DSL: /regex/i flag works (case-insensitive)');
    is_deeply($r2->{tags}, ['greeting'], 'DSL: then-tag action applied');

    # each rule keeps its OWN actions (shared-array regression from clam-old)
    my $two = Clam::Rules->parse("rule one\n when /a/\n then domain one\nend\nrule two\n when /b/\n then domain two\nend\n");
    is($two->[1]->execute({ text => 'b' })->{domain}, 'two', 'second rule keeps its own actions');
    is($two->[0]->execute({ text => 'a' })->{domain}, 'one', 'first rule unaffected by second parse');

    # bare pattern = literal string; /.../ = real regex (documented convention)
    my $lit = Clam::Rules->parse("rule lit\n when ^(?:a|b)\n then tag t\nend\n");
    ok($lit->[0]->test({ text => '^(?:a|b)' }), 'DSL: bare pattern matches literally');
    is($lit->[0]->test({ text => 'a' }), 0, 'DSL: bare pattern is not a regex');

    my $set = Clam::Rules->parse("rule s\n when /x/\n then set level high\nend\n");
    is($set->[0]->execute({ text => 'x' })->{level}, 'high', 'DSL: then-set action');

    ok(Clam::Rules::DSL->examples() =~ /rule classify_fix/, 'DSL: examples() returns sample program');
}

# ===========================================================================
# 6. Parser: Janet-style parse/classify/extract/transform/chain
# ===========================================================================
{
    my $s = Clam::Store->new(path => ':memory:');
    my $e = Clam::Rules::Engine->new(store => $s);
    my $dsl = <<'D';
rule classify_fix priority 20
    when /^(?:fix|bug)/
    then domain debug
end
rule shout
    when /world/
    then output HELLO WORLD
end
D
    $e->load(Clam::Rules->parse($dsl));
    my $p = Clam::Rules::Parser->new(engine => $e);

    is($p->classify('fix the build'), 'debug', 'parser: classify returns domain');
    is($p->classify('zzz nothing'), 'general', 'parser: no match -> general');

    is($p->parse('fix it')->{rule}, 'classify_fix', 'parser: reports which rule fired');
    is_deeply($p->extract('bug report'), { domain => 'debug' }, 'parser: extract returns result hashref');

    is($p->transform('hello world'), 'HELLO WORLD', 'parser: transform uses output action');
    is($p->transform('quiet text'), 'quiet text', 'parser: no match -> unchanged');

    # chain: a -> b -> c until stable (disjoint patterns keep it deterministic)
    my $s2 = Clam::Store->new(path => ':memory:');
    my $e2 = Clam::Rules::Engine->new(store => $s2);
    $e2->load(Clam::Rules->parse("rule step1\n when /a/\n then output b\nend\nrule step2\n when /b/\n then output c\nend\n"));
    my $c = Clam::Rules::Parser->new(engine => $e2)->chain('a');
    is($c->{final}, 'c', 'parser chain: transforms until no rule matches');
    is(scalar @{ $c->{steps} }, 2, 'parser chain: two steps recorded');
}
# ===========================================================================
# 7. DecisionTree: named-rule lookup, branching, persistence
# ===========================================================================
{
    my $s = Clam::Store->new(path => "$tmp/tree.db");
    my $e = Clam::Rules::Engine->new(store => $s);
    # catchall has HIGHER priority and matches everything: if the tree used an
    # engine-wide find() at root, catchall would win and the branch would fail.
    $e->add(Clam::Rules::Rule->new(name=>'catchall', type=>'pattern', priority=>99, match=>qr/./, action=>sub { { other => 1 } }));
    $e->add(Clam::Rules::Rule->new(name=>'is_fix',   type=>'pattern', match=>qr/^fix/, action=>sub { { fix => 1 } }));

    my $t = Clam::Rules::DecisionTree->new(engine => $e);
    $t->add_node('root', rule => 'is_fix', branches => { fix => 'fix_leaf' }, default => 'dflt');
    $t->add_node('fix_leaf', action => sub { return 'fixed' });
    $t->add_node('dflt',     action => sub { return 'defaulted' });

    my $r1 = $t->execute({ text => 'fix it' });
    is(join(',', @{ $r1->{path} }), 'root,fix_leaf', 'tree: named rule beats higher-priority catchall');
    is($r1->{result}, 'fixed', 'tree: leaf action result');

    my $r2 = $t->execute({ text => 'hello' });
    is(join(',', @{ $r2->{path} }), 'root,dflt', 'tree: unmatched rule -> default branch');
    is($r2->{result}, 'defaulted', 'tree: default leaf result');

    # unnamed internal node falls back to engine-wide find() (catchall wins)
    my $t2 = Clam::Rules::DecisionTree->new(engine => $e);
    $t2->add_node('root', branches => { other => 'other_leaf' });
    $t2->add_node('other_leaf', action => sub { return 'other' });
    is($t2->execute({ text => 'anything' })->{result}, 'other', 'tree: unnamed node uses engine find()');

    # a cycle hits the depth guard (root must name an existing node)
    my $t3 = Clam::Rules::DecisionTree->new(engine => $e, root => 'a');
    $t3->add_node('a', branches => { other => 'b' });
    $t3->add_node('b', branches => { other => 'a' });
    my $r3 = $t3->execute({ text => 'loop' });
    is(scalar @{ $r3->{path} }, 20, 'tree: cycle stops at depth guard');
    is($r3->{result}, undef, 'tree: no leaf reached -> undef result');

    like($t->visualize(), qr/fix_leaf/, 'tree: visualize shows branches');

    # persistence via kv (actions stripped on save)
    ok($t->save_to_store($s, 'smoke_tree'), 'tree: saved to store');
    my $t4 = Clam::Rules::DecisionTree->new(engine => $e);
    ok($t4->load_from_store($s, 'smoke_tree'), 'tree: loaded from store');
    my $r4 = $t4->execute({ text => 'fix it' });
    is(join(',', @{ $r4->{path} }), 'root,fix_leaf', 'tree: reloaded tree still branches correctly');
    is($r4->{result}, undef, 'tree: stripped leaf action -> undef (re-attach after load)');
}

# ===========================================================================
# 8. FSM: transitions, history, introspection
# ===========================================================================
{
    my $f = Clam::Rules::FSM->new(initial => 'idle');
    is($f->state, 'idle', 'fsm: initial state');
    my @actions;
    $f->add('idle', 'start', to => 'running', action => sub { push @actions, $_[0] });

    ok($f->can('start'), 'fsm: can() true for defined transition');
    is_deeply([ sort @{ $f->events } ], ['start'], 'fsm: events from current state');
    ok($f->fire('start'), 'fsm: valid transition fires');
    is($f->state, 'running', 'fsm: state advanced');
    is(scalar @actions, 1, 'fsm: action ran on transition');
    is($actions[0]{from}, 'idle', 'fsm: action got from-state');
    is($actions[0]{to}, 'running', 'fsm: action got to-state');

    $f->add('running', 'done', to => 'idle');
    is($f->fire('bogus'), 0, 'fsm: undefined event does not fire');
    is($f->state, 'running', 'fsm: state unchanged after failed fire');
    is(scalar @{ $f->history }, 1, 'fsm: history records only real transitions');

    my $g = Clam::Rules::FSM->new(initial => 'nowhere');
    is_deeply($g->events, [], 'fsm: events() on state with no transitions -> [] (no undef deref)');
    like($f->visualize(), qr/idle --\[start\]--> running/, 'fsm: visualize lists edges');
}

# ===========================================================================
# 9. BehaviorTree: node semantics + shared blackboard
# ===========================================================================
{
    my ($S, $F) = ('SUCCESS', 'FAILURE');

    my @ran;
    my $bt = Clam::Rules::BehaviorTree->new(tree => { type=>'sequence', children=>[
        { type=>'action', code=>sub { push @ran, 1; return } },
        { type=>'condition', code=>sub { 0 } },
        { type=>'action', code=>sub { push @ran, 3; return } },
    ]});
    is($bt->tick({}), $F, 'bt: sequence stops at first failure');
    is_deeply(\@ran, [1], 'bt: later children not run after failure');

    my $bt2 = Clam::Rules::BehaviorTree->new(tree => { type=>'selector', children=>[
        { type=>'condition', code=>sub { 0 } },
        { type=>'action', code=>sub { return } },
    ]});
    is($bt2->tick({}), $S, 'bt: selector returns first success');

    my $bt3 = Clam::Rules::BehaviorTree->new(tree => { type=>'selector', children=>[
        { type=>'condition', code=>sub { 0 } },
        { type=>'failer' },
    ]});
    is($bt3->tick({}), $F, 'bt: selector all-fail -> FAILURE');

    my $bt4 = Clam::Rules::BehaviorTree->new(tree => { type=>'parallel', threshold=>2, children=>[
        { type=>'succeeder' }, { type=>'succeeder' }, { type=>'failer' },
    ]});
    is($bt4->tick({}), $S, 'bt: parallel meets threshold');

    my $bt5 = Clam::Rules::BehaviorTree->new(tree => { type=>'inverter', child=>{ type=>'condition', code=>sub { 1 } } });
    is($bt5->tick({}), $F, 'bt: inverter flips SUCCESS -> FAILURE');

    my @count;
    my $bt6 = Clam::Rules::BehaviorTree->new(tree => { type=>'repeater', times=>3, child=>{ type=>'action', code=>sub { push @count, 1 } } });
    is($bt6->tick({}), $S, 'bt: repeater completes');
    is(scalar @count, 3, 'bt: repeater ran N times');

    my $n = 0;
    my $bt7 = Clam::Rules::BehaviorTree->new(tree => { type=>'repeater', child=>{ type=>'condition', code=>sub { my $ok = $n < 2; $n++; return $ok } } });
    is($bt7->tick({}), $S, 'bt: infinite repeater stops at failure');
    is($n, 3, 'bt: ran until condition failed (two passes + failing check)');

    my $bb = Clam::Rules::BehaviorTree->new(tree => { type=>'sequence', children=>[
        { type=>'action', code=>sub { $_[0]{blackboard}{x} = 42; return } },
        { type=>'condition', code=>sub { $_[0]{blackboard}{x} == 42 } },
    ]});
    is($bb->tick({}), $S, 'bt: blackboard shared across nodes');

    my $passthrough = Clam::Rules::BehaviorTree->new(tree => { type=>'action', code=>sub { return 'CUSTOM' } });
    is($passthrough->tick({}), 'CUSTOM', 'bt: defined action return passed through');
}

done_testing();
