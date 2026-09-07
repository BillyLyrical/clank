# AI::Clam::Rules::FSM — lightweight finite state machine. Hashref-based, no
# dependencies. States are keys, transitions are edges, actions fire on
# transition. Supports history, introspection, and visualization.
package AI::Clam::Rules::FSM;
use strict;
use warnings;

sub new {
    my ($class, %args) = @_;
    return bless {
        state       => $args{initial} // 'idle',
        transitions => {},   # from_state => { event => { to => state, action => sub } }
        history     => [],
    }, $class;
}

# Define a transition: on event in state, go to new state, run action.
sub add {
    my ($self, $from, $event, %opts) = @_;
    $self->{transitions}{$from}{$event} = {
        to     => $opts{to},
        action => $opts{action},
    };
}

# Fire an event. Returns 1 if transition succeeded, 0 if no valid transition.
sub fire {
    my ($self, $event, %ctx) = @_;
    my $from  = $self->{state};
    my $trans = $self->{transitions}{$from}{$event};
    return 0 unless $trans;

    push $self->{history}->@*, { from => $from, event => $event, to => $trans->{to}, time => time() };

    if ($trans->{action}) {
        $trans->{action}->({ from => $from, event => $event, to => $trans->{to}, %ctx });
    }

    $self->{state} = $trans->{to};
    return 1;
}

sub state   { return $_[0]->{state} }
sub history { return $_[0]->{history} }

# Check if event is valid from current state.
sub can {
    my ($self, $event) = @_;
    return exists $self->{transitions}{$self->{state}}{$event};
}

# List valid events from current state (empty list if none defined).
sub events {
    my ($self) = @_;
    return [ keys %{ $self->{transitions}{$self->{state}} // {} } ];
}

# Visualize the FSM.
sub visualize {
    my ($self) = @_;
    my $out = "Current: $self->{state}\n";
    for my $from (sort keys %{ $self->{transitions} }) {
        for my $event (sort keys %{ $self->{transitions}{$from} }) {
            my $to = $self->{transitions}{$from}{$event}{to};
            $out .= "  $from --[$event]--> $to\n";
        }
    }
    return $out;
}

1;
