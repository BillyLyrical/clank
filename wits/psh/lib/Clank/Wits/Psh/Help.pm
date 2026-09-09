# CLANK-WIT: name=Help
# CLANK-WIT: version=1.0.0
# CLANK-WIT: about=Show psh REPL help - commands, syntax, examples
# CLANK-WIT: usage=Input: { topic: "basics" } or { topic: "clank" } or { topic: "shell" } Output: { help: "..." }
# CLANK-WIT: hint=psh_help, help, REPL, commands, syntax, examples
# CLANK-WIT: author=Clank
# CLANK-WIT: license=Artistic-2.0
package Clank::Wits::Psh::Help;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'psh_help',
        description => 'Show psh REPL help - commands, syntax, examples',
        parameters  => {
            type       => 'object',
            properties => {
                topic => { type => 'string', description => 'Help topic: basics, clank, shell, vars, tips, all', default => 'all' },
            },
        },
        execute => sub {
            my ($args) = @_;
            my $topic = $args->{topic} // 'all';

            my %help = (
                basics => "PSH - Perl Shell inside Clank\n\n"
                        . "Type Perl code, press Enter twice to execute.\n"
                        . "Single Enter = line continuation.\n"
                        . "Empty line = execute buffered code.\n\n"
                        . "  !command      Execute shell command\n"
                        . "  /clank         Exit psh, return to Clank\n"
                        . "  /help         This help\n"
                        . "  /vars         List persisted variables\n",

                clank => "CALLING Clank WITS FROM PSH\n\n"
                      . "Use clank() to execute any loaded wit:\n\n"
                      . '  $result = clank("codebase.map", { intent => "authentication" })' . "\n"
                      . '  $result = clank("db.query", { sql => "SELECT * FROM users" })' . "\n"
                      . '  $result = clank("git.log", { count => 5 })' . "\n"
                      . "The function returns whatever the wit returns.\n",

                shell => "SHELL COMMANDS\n\n"
                       . "Prefix with ! to run shell commands:\n\n"
                       . "  psh> !ls -la\n"
                       . "  psh> !git status\n"
                       . "  psh> !grep -r TODO lib/\n\n"
                       . "Shell output becomes the result.\n",

                vars => "VARIABLES\n\n"
                      . "Variables declared with 'our' persist between evals:\n\n"
                      . "  psh> our \$dbh = DBI->connect(...)\n"
                      . "  psh> # \$dbh is still there next eval\n\n"
                      . "Variables declared with 'my' are local.\n"
                      . "/vars lists persisted variables.\n",

                tips => "TIPS\n\n"
                      . "Use Clank modules directly:\n"
                      . "  psh> use Clank::Auth\n"
                      . "  psh> my \$auth = Clank::Auth->new\n\n"
                      . "Chain commands:\n"
                      . '  psh> $result = clank("db.query", { sql => "SELECT count(*) FROM users" })' . "\n"
                      . '  psh> say "Count: $result"' . "\n",
            );

            $help{all} = join("\n", values %help);

            my $text = $help{$topic} // $help{all};

            return {
                topic => 'psh.help',
                help  => $text,
                topic_name => $topic,
            };
        },
    );
}

1;
