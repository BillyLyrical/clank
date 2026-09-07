# CLAM-WIT: name=Help
# CLAM-WIT: version=1.0.0
# CLAM-WIT: about=Show psh REPL help - commands, syntax, examples
# CLAM-WIT: usage=Input: { topic: "basics" } or { topic: "clam" } or { topic: "shell" } Output: { help: "..." }
# CLAM-WIT: hint=psh_help, help, REPL, commands, syntax, examples
# CLAM-WIT: author=CLAM
# CLAM-WIT: license=Artistic-2.0
package AI::Clam::Wits::Psh::Help;
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
                topic => { type => 'string', description => 'Help topic: basics, clam, shell, vars, tips, all', default => 'all' },
            },
        },
        execute => sub {
            my ($args) = @_;
            my $topic = $args->{topic} // 'all';

            my %help = (
                basics => "PSH - Perl Shell inside CLAM\n\n"
                        . "Type Perl code, press Enter twice to execute.\n"
                        . "Single Enter = line continuation.\n"
                        . "Empty line = execute buffered code.\n\n"
                        . "  !command      Execute shell command\n"
                        . "  /clam         Exit psh, return to CLAM\n"
                        . "  /help         This help\n"
                        . "  /vars         List persisted variables\n",

                clam => "CALLING CLAM WITS FROM PSH\n\n"
                      . "Use clam() to execute any loaded wit:\n\n"
                      . '  $result = clam("codebase.map", { intent => "authentication" })' . "\n"
                      . '  $result = clam("db.query", { sql => "SELECT * FROM users" })' . "\n"
                      . '  $result = clam("git.log", { count => 5 })' . "\n"
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
                      . "Use Clam modules directly:\n"
                      . "  psh> use AI::Clam::Auth\n"
                      . "  psh> my \$auth = AI::Clam::Auth->new\n\n"
                      . "Chain commands:\n"
                      . '  psh> $result = clam("db.query", { sql => "SELECT count(*) FROM users" })' . "\n"
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
