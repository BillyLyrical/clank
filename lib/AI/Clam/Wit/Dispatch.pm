# AI::Clam::Wit::Dispatch — inter-wit execution, the object wits receive as
# $ctx{wits}.  Mirrors the clam-old Executor's execute-by-name semantics:
#   my $r = eval { $ctx{wits}->execute('deduction.axiom', $input) };
# Returns the result hashref or undef; failures are warned and swallowed so a
# broken callee never takes down its caller (orchestration wits like
# deduction.deduce rely on this).  A depth guard stops recursive loops.
package AI::Clam::Wit::Dispatch;
use strict;
use warnings;

sub new {
    my ($class, %o) = @_;
    return bless { wits => $o{wits} // {}, depth => 0 }, $class;
}

# execute($name_or_trigger, $input) -> result|undef
sub execute {
    my ($self, $name, $input) = @_;
    my $rec = $self->{wits}{$name};
    return undef unless $rec;

    die "wit dispatch depth exceeded at '$name'\n" if ++$self->{depth} > 10;
    my ($result, $error);
    eval {
        ($result, $error) = $rec->{run_notimeout}->(ref $input eq 'HASH' ? $input : (defined $input ? { text => "$input" } : {}));
        1;
    } or do {
        warn "[wits] dispatch error in '$name': $@";
    };
    --$self->{depth};

    warn "[wits] wit '$name' failed: $error" if $error;
    return $result;
}

# Names currently resolvable (for diagnostics / tests).
sub names { sort keys %{ $_[0]->{wits} } }

1;
