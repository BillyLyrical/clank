# Knowledge base: facts + rules, indexed by predicate name.
#   fact = [ 'pred', arg, ... ]
#   rule = { head => [ 'pred', arg, ... ], body => [ ['goal',...], ... ] }
package AI::Clam::Logic::KnowledgeBase;
use strict;
use warnings;

sub new { my ($class) = @_; return bless { facts => [], rules => [], _idx => undef }, $class }

sub add_fact { my ($s, $f) = @_; push @{ $s->{facts} }, $f; $s->{_idx} = undef; return $s }
sub add_rule { my ($s, $r) = @_; push @{ $s->{rules} }, $r; $s->{_idx} = undef; return $s }
sub clear    { $_[0]->{facts} = []; $_[0]->{rules} = []; $_[0]{_idx} = undef; $_[0] }

sub facts { @{ $_[0]->{facts} } }
sub rules { @{ $_[0]->{rules} } }
sub size  { scalar(@{ $_[0]->{facts} }) + scalar(@{ $_[0]->{rules} }) }

# Clauses (facts and rule heads) whose predicate matches. Returns an arrayref
# (NOT a list — callers dereference, which would force scalar context).
sub entries_for {
    my ($self, $pred) = @_;
    $self->{_idx} //= _build_index($self);
    return $self->{_idx}{$pred} // [];
}

sub _build_index {
    my ($self) = @_;
    my %idx;
    push @{ $idx{ $_->[0] } }, { kind => 'fact', term => $_ } for @{ $self->{facts} };
    push @{ $idx{ $_->{head}[0] } }, { kind => 'rule', rule => $_ } for @{ $self->{rules} };
    return \%idx;
}

1;
