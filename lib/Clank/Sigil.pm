# Clank::Sigil — shared sigil-based dispatch for command harnesses.
# Parses input lines on first character, routes to registered handlers.
# Transport-agnostic: REPL, clankd, and future harnesses all use it.
package Clank::Sigil;
use strict;
use warnings;

sub new {
    my ($class, %o) = @_;
    return bless {
        app      => $o{app},
        handlers => {},
    }, $class;
}

sub app { $_[0]->{app} }

# Register a handler for a sigil character.
# handler receives ($app, $content_after_sigil) and returns {output => '...'} or undef.
sub register {
    my ($self, $sigil, $handler) = @_;
    $self->{handlers}{$sigil} = $handler;
    return $self;
}

# Parse a line and dispatch. Returns {output => '...'} or undef.
# undef means "not a command — fall through to LLM prompt".
sub dispatch {
    my ($self, $line) = @_;
    return undef unless defined $line && length $line;

    my $sigil = substr($line, 0, 1);
    my $handler = $self->{handlers}{$sigil};
    return undef unless $handler;

    my $content = substr($line, 1);
    $content =~ s/^\s+//;

    my $result = eval { $handler->($self->{app}, $content) };
    if ($@) {
        return { output => "sigil $sigil error: $@" };
    }
    return $result;
}

# Check if a line starts with a registered sigil.
sub is_command {
    my ($self, $line) = @_;
    return 0 unless defined $line && length $line;
    my $sigil = substr($line, 0, 1);
    return exists $self->{handlers}{$sigil} ? 1 : 0;
}

1;
