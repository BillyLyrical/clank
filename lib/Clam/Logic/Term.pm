# Term model for the Datalog engine. Terms: atoms (strings/numbers),
# variables (?name, Name, _Name), lists (arrayrefs).
package Clam::Logic::Term;
use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(is_var is_atom resolve render render_head);

sub is_var {
    my ($t) = @_;
    return defined($t) && !ref($t) && $t =~ /^[?_A-Z]/ ? 1 : 0;
}

sub is_atom {
    my ($t) = @_;
    return defined($t) && !ref($t) && !is_var($t);
}

# Deep variable resolution against an env (var => term). Transitive: follows
# var->var chains until a non-variable or unbound variable is reached.
sub resolve {
    my ($t, $env) = @_;
    if (!ref $t) {
        return $t unless is_var($t);
        my %seen;
        while (is_var($t) && exists $env->{$t} && !$seen{$t}++) { $t = $env->{$t} }
        return $t;
    }
    return [ map { resolve($_, $env) } @$t ];
}

# Render a term back to source text.
sub render {
    my ($t) = @_;
    if (!ref $t) {
        return is_var($t) ? "?$t" : "$t";
    }
    return '[' . join(', ', map { render($_) } @$t) . ']';
}

# Render a goal/fact [pred, args...] as pred(a,b).
sub render_head {
    my ($h) = @_;
    return $h->[0] . '(' . join(', ', map { render($_) } @{ $h }[1 .. $#$h]) . ')';
}

1;
