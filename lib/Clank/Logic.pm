# Datalog engine facade: parse programs, run queries.
package Clank::Logic;
use strict;
use warnings;
use Clank::Logic::Parser ();
use Clank::Logic::Solver ();
use Clank::Logic::Term ();

our $VERSION = '0.1.0';

# Parse a Datalog program -> KnowledgeBase.  (method: Clank::Logic->parse($text))
sub parse {
    my ($class, $text) = @_;
    return Clank::Logic::Parser->parse($text);
}

# Query: goal as [pred, args...] or source text ("gp(X,Y)").
# Returns arrayref of solution envs (var => term).  (method call)
sub query {
    my ($class, $kb, $goal, $opts) = @_;
    if (!ref $goal) {
        my $tmp   = Clank::Logic::Parser->parse("$goal.");
        my @facts = $tmp->facts;
        die "query: expected a single goal, got " . scalar(@facts) . "\n" unless @facts == 1;
        $goal = $facts[0];
    }
    return Clank::Logic::Solver::solve($goal, $kb, $opts // {});
}

# Convenience: run program + goal in one call.  (method call)
sub run {
    my ($class, $program, $goal, $opts) = @_;
    return $class->query($class->parse($program), $goal, $opts);
}

1;
