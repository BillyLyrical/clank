# AI::Clam::Rules — rule engine facade: parse DSL, build engines over a store.
# The fact store is shared SQLite state (AI::Clam::Store) — every agent on the same
# DB reads and writes the same blackboard; this module stays bus-free so wits
# wire it into the pub/sub web via $ctx{bus}.
#
# Features:
#   - Forward chaining with conflict resolution
#   - Backward chaining for goal-directed reasoning
#   - Negation as failure (not_exists conditions)
#   - Rule composition (pipeline execution)
#   - Incremental re-evaluation
package AI::Clam::Rules;
use strict;
use warnings;
use AI::Clam::Rules::DSL ();
use AI::Clam::Rules::Engine ();

our $VERSION = '0.2.0';

# Parse a rules-DSL program -> arrayref of AI::Clam::Rules::Rule.  (method call)
sub parse {
    my ($class, $text) = @_;
    return AI::Clam::Rules::DSL->parse($text);
}

# Build an engine over a store, optionally pre-loaded with DSL rules:
#   AI::Clam::Rules->engine(store => $store, strategy => 'first', dsl => <<'D')
sub engine {
    my ($class, %args) = @_;
    my $engine = AI::Clam::Rules::Engine->new(%args);
    if (defined $args{dsl}) {
        $engine->load(AI::Clam::Rules::DSL->parse($args{dsl}));
    }
    return $engine;
}

# Convenience: prove a goal is true via backward chaining.
sub prove {
    my ($class, $engine, $goal_type, $goal_attrs) = @_;
    return $engine->prove($goal_type, $goal_attrs);
}

# Convenience: re-evaluate rules affected by changed fact types.
sub re_evaluate {
    my ($class, $engine, $changed_types) = @_;
    return $engine->re_evaluate($changed_types);
}

1;

__END__

=encoding utf-8

=head1 NAME

AI::Clam::Rules - Rule engine facade with forward/backward chaining, negation,
conflict resolution, rule composition, and incremental re-evaluation.

=head1 SYNOPSIS

  use AI::Clam::Rules;
  use AI::Clam::Store;

  my $store = AI::Clam::Store->new(db => 'clam.db');
  my $engine = AI::Clam::Rules->engine(store => $store, strategy => 'first');

  # Add production rules
  $engine->add(AI::Clam::Rules::Rule->new(
      name       => 'ancestor',
      type       => 'production',
      priority   => 10,
      conditions => [
          { type => 'parent', parent => '$p', child => '$c' },
      ],
      action     => sub { ... },
  ));

  # Forward chaining
  $engine->chain();

  # Backward chaining — prove a goal
  my $proof = $engine->prove('ancestor', { ancestor => 'Bob', descendant => 'Alice' });

  # Rule composition — pipeline
  my $result = $engine->chain_rules('step1', 'step2', 'step3');

  # Incremental re-evaluation
  $engine->re_evaluate(['sensor', 'reading']);

=head1 DESCRIPTION

AI::Clam::Rules is the rule engine facade. It parses DSL rules, builds engines
over a shared SQLite fact store (AI::Clam::Store), and provides multiple inference
strategies. The fact store is the blackboard every agent on this DB reads and
writes; this module stays bus-free so wits wire it into the pub/sub web via
C<$ctx{bus}>.

=head1 FEATURES

=head2 Forward Chaining

Production rules fire in a loop: match conditions against facts, execute
action, assert new facts, repeat until fixpoint or max depth.

  my $result = $engine->chain(\@initial_facts);

Returns C<{ iterations, facts_asserted, rules_fired, max_reached, log }>.

=head2 Backward Chaining

Goal-directed reasoning. Given a goal type and attributes, traces backward
through production rules to determine if the goal can be proven.

  my $proof = $engine->prove('relative', { person => 'Alice' });
  # $proof = { proven => 1, proof => [...], steps => 3 }

Works by:
1. Checking if the goal fact already exists.
2. Trying each production rule whose action could produce the goal type.
3. Recursively proving each condition of matching rules.

Includes cycle detection via depth limit (C<max_chain_depth>).

=head2 Negation as Failure

Conditions can specify C<not_exists => 1> to succeed when a matching fact
does NOT exist:

  $engine->add(AI::Clam::Rules::Rule->new(
      name       => 'check_not_banned',
      type       => 'production',
      conditions => [
          { type => 'user', name => 'Bob' },
          { type => 'ban', name => 'Bob', not_exists => 1 },
      ],
      action     => sub { ... },
  ));

Standalone check:

  if ($engine->not_exists('ban', { name => 'Bob' })) {
      # Bob is not banned
  }

=head2 Conflict Resolution

When multiple rules fire simultaneously, C<resolve_conflicts()> selects
winners based on the engine strategy:

  my @winners = $engine->resolve_conflicts(@fired_rules);

Strategies:

=over 4

=item first - highest priority wins (default)

=item random - one random winner

=item probabilistic - weighted by rule weight

=item all - all rules fire

=back

Use C<chain_with_resolution()> for forward chaining with conflict resolution
enforced per iteration instead of firing all matching rules:

  my $result = $engine->chain_with_resolution(\@initial_facts);

=head2 Rule Composition

Execute a pipeline of named rules, passing each rule's output as context
input to the next:

  my $pipeline = $engine->chain_rules('step1', 'step2', 'step3');
  # $pipeline = { pipeline => [...], final => {...}, steps => 3 }

Each rule receives the accumulated context from prior steps. Hash results
are merged into the context; scalar results are stored under C<result>.

=head2 Incremental Re-evaluation

When facts change, only re-evaluate rules that depend on those fact types
instead of re-running the full chain:

  my $reeval = $engine->re_evaluate(['sensor', 'temperature']);
  # $reeval = { affected => [...], re_evaluated => [...], count => 2 }

The dependency graph is built automatically from production rule conditions.

=head1 CLASS METHODS

=head2 parse($dsl_text)

Parse a rules-DSL program into an arrayref of AI::Clam::Rules::Rule configs.

=head2 engine(%args)

Build an engine. Required: C<store>. Optional: C<strategy>, C<max_chain_depth>,
C<dsl> (auto-parsed DSL text).

=head2 prove($engine, $goal_type, $goal_attrs)

Convenience wrapper for C<< $engine->prove() >>.

=head2 re_evaluate($engine, $changed_types)

Convenience wrapper for C<< $engine->re_evaluate() >>.

=head1 SEE ALSO

L<AI::Clam::Rules::Engine>, L<AI::Clam::Rules::Rule>, L<AI::Clam::Rules::DSL>,
L<AI::Clam::Store>

=cut
