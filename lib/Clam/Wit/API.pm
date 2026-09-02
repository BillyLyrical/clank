# What a Wit receives at register() time (mirrors Pi's ExtensionAPI).
package Clam::Wit::API;
use strict;
use warnings;

sub new {
    my ($class, %o) = @_;
    return bless {
        bus       => $o{bus},
        store     => $o{store},
        session   => $o{session},
        ui        => $o{ui} // Clam::Wit::API::UI->new,
        wit_name  => $o{wit_name} // 'anon',
        tools     => [],
        commands  => {},
    }, $class;
}

sub bus        { $_[0]->{bus} }
sub store      { $_[0]->{store} }
sub session    { $_[0]->{session} }
sub ui         { $_[0]->{ui} }
sub wit_name   { $_[0]->{wit_name} }

# Subscribe a handler to an event topic (Pi: api.on(event, handler)).
# Handler receives the full event hashref {id, correlation_id, topic, sender, payload}.
# Return a result hashref (per-topic reducer rules apply) or undef.
# Throwing handlers are caught by Bus and journaled under wit.error.
sub on {
    my ($self, $event, $handler) = @_;
    die "api->on: handler must be a coderef" unless ref $handler eq 'CODE';
    $self->{bus}->subscribe($event, sub {
        my ($ev) = @_;
        return $handler->({ %$ev });
    }, name => "wit:" . $self->{wit_name});
}

# Register a tool callable by the LLM (Pi: api.registerTool).
sub register_tool {
    my ($self, %def) = @_;
    die "register_tool: name required" unless defined $def{name};
    die "register_tool: execute coderef required" unless ref($def{execute} // '') eq 'CODE';
    push @{ $self->{tools} }, \%def;
    return $def{name};
}

# Register a REPL slash command (Pi: api.registerCommand).
sub register_command {
    my ($self, $name, %def) = @_;
    $name =~ s{^/}{};
    die "register_command: handler required" unless ref($def{handler} // '') eq 'CODE';
    $self->{commands}{$name} = { description => $def{description}, handler => $def{handler} };
    return $name;
}

# Return refs (not lists): callers dereference, and list-returning accessors
# misbehave in scalar context (e.g. `@{ $api->registered_tools }`).
sub registered_tools    { $_[0]->{tools} }
sub registered_commands { $_[0]->{commands} }

# ---------------------------------------------------------------------------
package Clam::Wit::API::UI;
# Readline-backed UI (REPL may swap in its own object with the same methods).
use strict;
use warnings;

sub new { bless {}, shift }

sub notify  { my ($s, $msg) = @_; print "[wit] $msg\n" }

sub input   {
    my ($s, $prompt, $default) = @_;
    print $prompt;
    chomp(my $v = <STDIN>);
    return length($v) ? $v : $default;
}

sub confirm {
    my ($s, $q) = @_;
    print "$q [y/N] ";
    chomp(my $a = <STDIN>);
    return $a =~ /^y/i ? 1 : 0;
}

sub select  {
    my ($s, $prompt, @opts) = @_;
    print "$prompt\n";
    for my $i (0 .. $#opts) { print "  ", $i + 1, ". $opts[$i]\n" }
    chomp(my $a = <STDIN>);
    return (defined $a && $a =~ /^\d+$/ && $a - 1 <= $#opts) ? $opts[$a - 1] : undef;
}

1;
