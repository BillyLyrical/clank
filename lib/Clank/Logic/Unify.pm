# Unification with occurs check. Pure: returns a NEW env hashref, never mutates.
package Clank::Logic::Unify;
use strict;
use warnings;
use Exporter 'import';
use Clank::Logic::Term qw(is_var resolve);

# NOTE: no public 'bind' — that name collides with CORE::bind (sockets).
our @EXPORT_OK = qw(unify);

sub _looks_num { my ($x) = @_; return defined($x) && !ref($x) && $x =~ /^-?\d+(?:\.\d+)?$/ }

# unify($a, $b, $env) -> new env | undef on failure.
sub unify {
    my ($a, $b, $env) = @_;
    $env //= {};

    # a variable unifies with ANY term (atom or list); _bind handles the
    # already-bound case by unifying the existing value instead of rebinding
    return _bind($a, resolve($b, $env), $env) if is_var($a);
    return _bind($b, resolve($a, $env), $env) if is_var($b);

    if (!ref $a && !ref $b) {
        my $eq = ($a eq $b) || ((_looks_num($a) && _looks_num($b)) ? ($a == $b) : 0);
        return $eq ? { %$env } : undef;
    }

    if (ref($a) eq 'ARRAY' && ref($b) eq 'ARRAY') {
        return undef unless @$a == @$b;
        my $e = $env;
        for my $i (0 .. $#$a) {
            $e = unify($a->[$i], $b->[$i], $e);
            return undef unless $e;
        }
        return $e;
    }

    return undef;   # shape mismatch (atom vs list, etc.)
}

# Bind var to a fully-resolved term, with occurs check. If the variable is
# already bound in $env, unify its existing value with the term instead of
# silently rebinding it (rebinding destroys constraints and yields spurious
# solutions).
sub _bind {
    my ($var, $term, $env) = @_;   # $term fully resolved
    if (exists $env->{$var}) {
        return unify(resolve($var, $env), $term, $env);
    }
    return undef if _occurs($var, $term);
    my %e = %$env;
    $e{$var} = $term;
    return \%e;
}

sub _occurs {
    my ($var, $t) = @_;
    return 0 unless defined $t;
    if (!ref $t) {
        return is_var($t) ? ($t eq $var ? 1 : 0) : 0;
    }
    for my $x (@$t) { return 1 if _occurs($var, $x) }
    return 0;
}

1;
