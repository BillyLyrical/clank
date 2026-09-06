# CLAM-WIT: name=Hello
# CLAM-WIT: version=1.0
# CLAM-WIT: about=Example wit showing tool, command, and bus hook registration
# CLAM-WIT: usage=Template for writing your own wits. Load to try it.
# CLAM-WIT: hint=Example: greet tool, /hello command, input tagging hook
# CLAM-WIT: author=clam
# CLAM-WIT: license=Artistic-2.0
#
# The smallest useful wit — a template for writing your own. Shows all three
# registration surfaces: a tool, a REPL slash command, and an event hook.
#
# Install (optional; discovery also finds it in place):
#   cpanm .  (from this directory)
#
# Layout: standard wit layout — lib/Clam/Wits/<Name>.pm

package Clam::Wits::Hello;
use strict; use warnings;

sub register {
    my ($self, $api) = @_;

    # 1) A tool the LLM can call.
    $api->register_tool(
        name        => 'greet',
        description => 'Greet someone by name',
        parameters  => {
            type       => 'object',
            properties => { who => { type => 'string', description => 'Name to greet' } },
            required   => ['who'],
        },
        execute => sub {
            my ($args) = @_;
            return "hello, $args->{who}!";
        },
    );

    # 2) A REPL slash command: /hello [text]
    $api->register_command('hello', description => 'say hi from the hello wit', handler => sub {
        my ($ctx, $args) = @_;
        return "hi from the hello wit" . (length($args) ? " ($args)" : '');
    });

    # 3) An event hook: tag every user input (demonstrates bus subscription).
    # Uncomment to try it — it rewrites all prompts, which is usually unwanted.
    # $api->on('input', sub {
    #     my ($ev) = @_;
    #     return { action => 'transform', text => $ev->{payload}{text} . ' [hello-wit]' };
    # });

    $api->ui->notify("hello wit loaded (tool: greet, command: /hello)") if $api->ui;
}

1;
