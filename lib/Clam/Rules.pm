# Clam::Rules — rule engine facade: parse DSL, build engines over a store.
# The fact store is shared SQLite state (Clam::Store) — every agent on the same
# DB reads and writes the same blackboard; this module stays bus-free so wits
# wire it into the pub/sub web via $ctx{bus}.
package Clam::Rules;
use strict;
use warnings;
use Clam::Rules::DSL ();
use Clam::Rules::Engine ();

our $VERSION = '0.1.0';

# Parse a rules-DSL program -> arrayref of Clam::Rules::Rule.  (method call)
sub parse {
    my ($class, $text) = @_;
    return Clam::Rules::DSL->parse($text);
}

# Build an engine over a store, optionally pre-loaded with DSL rules:
#   Clam::Rules->engine(store => $store, strategy => 'first', dsl => <<'D')
sub engine {
    my ($class, %args) = @_;
    my $engine = Clam::Rules::Engine->new(%args);
    if (defined $args{dsl}) {
        $engine->load(Clam::Rules::DSL->parse($args{dsl}));
    }
    return $engine;
}

1;
