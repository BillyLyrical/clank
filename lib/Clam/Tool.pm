package Clam::Tool;
use strict; use warnings;
# Base class for built-in tools (Pi parity: name/description/parameters/execute).

sub new { my ($class, %o) = @_; return bless { %o }, $class; }

# Run with error capture. Returns { output => str, isError => 0|1 }.
# execute is either a method (builtin tools) or a coderef in the hash
# (wit-registered tools via api->register_tool).
sub run {
    my ($self, $args) = @_;
    $args //= {};
    my $r = eval {
        ref($self->{execute} // '') eq 'CODE' ? $self->{execute}->($args) : $self->execute($args);
    };
    if ($@) { return { output => "error: $@", isError => 1 }; }
    return ref $r eq 'HASH' ? $r : { output => defined $r ? "$r" : '', isError => 0 };
}

# OpenAI function-calling schema.
sub openai_schema {
    my ($self) = @_;
    return { type => 'function',
             function => { name => $self->{name}, description => $self->{description}, parameters => $self->{parameters} } };
}

1;
