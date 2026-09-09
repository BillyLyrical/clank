# SLD resolution over a KnowledgeBase (Datalog: no function symbols, so
# derivations terminate). Solutions are envs mapping the goal's variables to
# resolved terms. Options are passed as a hashref: { max_depth => N,
# max_solutions => N }.
package Clank::Logic::Solver;
use strict;
use warnings;
use Clank::Logic::Term qw(is_var resolve);
use Clank::Logic::Unify qw(unify);

my $_fresh_n = 0;

# solve($goal, $kb, \%opts) -> arrayref of solution envs (capped).
sub solve {
    my ($goal, $kb, $o) = @_;
    $o //= {};
    my $max_depth = $o->{max_depth} // 50;
    my $max_sols  = $o->{max_solutions} // 100;
    my @sols;
    _solve([ $goal ], {}, $kb, 0, \@sols, $max_depth, $max_sols);
    return [ map { _project($_, $goal) } @sols ];
}

# First solution env (projected onto the goal's variables), or undef.
sub prove_first {
    my ($goal, $kb, $o) = @_;
    $o //= {};
    my $sols = solve($goal, $kb, { %$o, max_solutions => 1 });
    return @$sols ? $sols->[0] : undef;
}

# Lazy iterator: each call returns the next solution env, or undef when done.
sub prove_all {
    my ($goal, $kb, $o) = @_;
    my @sols = @{ solve($goal, $kb, $o // {}) };
    my $i = 0;
    return sub { $i <= $#sols ? $sols[$i++] : undef };
}

sub _solve {
    my ($goals, $env, $kb, $depth, $sols, $max_depth, $max_sols) = @_;
    return if @$sols >= $max_sols;
    if (!@$goals) { push @$sols, { %$env }; return }
    die "derivation depth limit ($max_depth)\n" if $depth > $max_depth;

    my $head = $goals->[0];
    my @rest = @$goals[1 .. $#$goals];
    my $pred = $head->[0];

    for my $entry (@{ $kb->entries_for($pred) }) {
        last if @$sols >= $max_sols;
        my ($clause, $body);
        if ($entry->{kind} eq 'fact') {
            ($clause, $body) = ($entry->{term}, []);
        } else {
            ($clause, $body) = ($entry->{rule}{head}, $entry->{rule}{body});
        }

        # Rename ALL clause vars (head AND body) fresh per instantiation,
        # sharing one map so vars shared within the rule stay linked. Without
        # head renaming, a query var with the same name as a head var gets
        # captured by the clause instead of being solved for.
        my %seen;
        my $fresh_clause = [ map { _fresh($_, \%seen) } @$clause ];
        my @fresh_body   = map { [ map { _fresh($_, \%seen) } @$_ ] } @$body;

        if (my $e2 = unify($head, $fresh_clause, $env)) {
            _solve([ @fresh_body, @rest ], $e2, $kb, $depth + 1, $sols, $max_depth, $max_sols);
        }
    }
}

# Project a full solution env onto the variables appearing in $goal, with
# values resolved against the full env (internal _G* vars never leak out).
# A goal var left unbound by every derivation is omitted.
sub _project {
    my ($env, $goal) = @_;
    my %out;
    for my $v (_collect_vars($goal)) {
        next unless exists $env->{$v};
        $out{$v} = resolve($env->{$v}, $env);
    }
    return \%out;
}

sub _collect_vars {
    my ($t) = @_;
    if (!ref $t) {
        return is_var($t) ? ($t) : ();
    }
    return map { _collect_vars($_) } @$t;
}

# Rename a term's variables to fresh names via the shared %seen map.
sub _fresh {
    my ($t, $seen) = @_;
    if (!ref $t) {
        return $t unless is_var($t);
        return $seen->{$t} if exists $seen->{$t};
        my $nv = "_G" . ($_fresh_n++);
        $seen->{$t} = $nv;
        return $nv;
    }
    return [ map { _fresh($_, $seen) } @$t ];
}

1;
