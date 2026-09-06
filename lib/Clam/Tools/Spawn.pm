# Clam::Tools::Spawn — create a subagent that runs a prompt in an isolated session.
package Clam::Tools::Spawn;
use strict;
use warnings;
use parent 'Clam::Tool';

sub new {
    my ($class, %o) = @_;
    return $class->SUPER::new(
        name        => 'spawn',
        description => "Spawn a subagent to handle a task in an isolated session. The subagent gets its own context but shares the same bus, store, and tools. Use for parallel work, research tasks, or anything that benefits from a fresh context. Returns the subagent's final output.",
        parameters  => {
            type       => 'object',
            properties => {
                prompt    => { type => 'string',  description => 'The task for the subagent to perform' },
                name      => { type => 'string',  description => 'Optional name for the subagent session' },
                max_turns => { type => 'number',  description => 'Max turns (default 30)' },
            },
            required => ['prompt'],
        },
        loop => $o{loop},
    );
}

sub execute {
    my ($self, $args) = @_;
    my $prompt = $args->{prompt} or return { output => "error: prompt is required", isError => 1 };
    my $loop   = $self->{loop}   or return { output => "error: loop not available", isError => 1 };

    my $result = $loop->spawn(
        prompt    => $prompt,
        name      => $args->{name},
        max_turns => $args->{max_turns},
    );

    if ($result->{ok}) {
        return { output => $result->{output} || "(subagent completed with no output)", isError => 0 };
    } else {
        return { output => "subagent error: " . ($result->{error} // 'unknown'), isError => 1 };
    }
}

1;
