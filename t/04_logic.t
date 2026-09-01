use strict; use warnings;
use Test::More;
use lib 'lib';
use Clam::Logic;
use Clam::Logic::Solver ();
use Clam::Logic::Unify qw(unify);

my $program = <<'EOF';
% family facts
parent(alice, bob).
parent(alice, carol).
parent(bob, dave).
parent(carol, erin).
male(alice).
female(bob).
female(carol).
male(dave).
female(erin).

% rules
grandparent(X,Y) :- parent(X,Z), parent(Z,Y).
ancestor(X,Y)   :- parent(X,Y).
ancestor(X,Y)   :- parent(X,Z), ancestor(Z,Y).
EOF

my $kb = Clam::Logic->parse($program);
is($kb->size, 12, '9 facts + 3 rules parsed');

# direct fact query
my @sols = @{ Clam::Logic->query($kb, 'parent(alice, X)') };
is(scalar(@sols), 2, 'two children of alice');
my %kids = map { ($_->{X} // '?') => 1 } @sols;
ok($kids{bob} && $kids{carol}, 'children are bob+carol');

# grandparent via rule composition
@sols = @{ Clam::Logic->query($kb, 'grandparent(alice, X)') };
is(scalar(@sols), 2, 'two grandchildren');
%kids = map { ($_->{X} // '?') => 1 } @sols;
ok($kids{dave} && $kids{erin}, 'grandchildren are dave+erin');

# transitive closure (ancestor): alice->bob->dave and alice->carol->erin
@sols = @{ Clam::Logic->query($kb, 'ancestor(alice, X)') };
%kids = map { ($_->{X} // '?') => 1 } @sols;
ok($kids{bob} && $kids{carol} && $kids{dave} && $kids{erin}, 'transitive closure complete');

# no-solution query
@sols = @{ Clam::Logic->query($kb, 'parent(dave, X)') };
is(scalar(@sols), 0, 'no solutions for leaf node');

# fully-ground queries: true/false
ok(defined Clam::Logic::Solver::prove_first(['parent','alice','bob'], $kb), 'ground fact proves');
is(Clam::Logic::Solver::prove_first(['parent','bob','alice'], $kb), undef, 'reversed fact fails');

# unification unit checks (incl. occurs check)
is(unify('X', ['X'], {}), undef, 'occurs check rejects X = [X]');
ok(defined unify('X', ['Y','a'], {}), 'simple list bind ok');
my $e = unify(['?A','b'], ['x','?B'], {});
is($e->{'?A'}, 'x', 'list element unification 1');
is($e->{'?B'}, 'b', 'list element unification 2');

# lists as terms in queries
my $kb2 = Clam::Logic->parse("has(a, [1, 2]).\nhas(b, [3, X]).");
@sols = @{ Clam::Logic->query($kb2, 'has(Z, [1, N])') };
is(scalar(@sols), 1, 'list unification matches one');
is($sols[0]{Z}, 'a', 'list match found a');

# run() convenience: program + goal in one call
my $r = Clam::Logic->run('p(42).', 'p(X)');
is(scalar(@$r), 1, 'run() finds solution');
is($r->[0]{X}, 42, 'run() binds X=42');

# lazy iterator
my $it = Clam::Logic::Solver::prove_all(['parent','alice','X'], $kb);
my @all;
while (my $env = $it->()) { push @all, $env->{X} }
is(scalar(@all), 2, 'iterator yields all solutions');

# parse errors are clean dies
eval { Clam::Logic->parse("parent(alice bob).") };
like($@, qr/parse error/, 'missing comma -> parse error');
eval { Clam::Logic->parse("parent(alice,).") };
like($@, qr/parse error/, 'trailing comma -> parse error');

done_testing();
