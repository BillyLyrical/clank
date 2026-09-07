# CLAM-WIT: name=Shell
# CLAM-WIT: version=1.0.0
# CLAM-WIT: about=Interactive database shell — REPL for exploring and managing databases
# CLAM-WIT: usage=Input: { action: "start", db: "my.db" } Output: { ok: true, message: "..." }
# CLAM-WIT: hint=database shell, repl, interactive, explore
# CLAM-WIT: author=CLAM
# CLAM-WIT: license=Artistic-2.0
package AI::Clam::Wits::Db::Shell;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;
    $api->register_tool(
        name        => 'db_shell',
        description => 'Interactive database shell — REPL for exploring and managing databases',
        parameters  => {
            type       => 'object',
            properties => {
                action => { type => 'string', enum => ['start', 'exec', 'status', 'prompt'] },
                db     => { type => 'string' },
                input  => { type => 'string' },
                prompt => { type => 'string' },
            },
            required => ['action'],
        },
        execute => sub {
            my ($args) = @_;
            my $action = $args->{action} // 'exec';

            # Note: This tool requires access to session state and other wits.
            # The actual implementation depends on the Clam runtime environment.
            # This is a skeleton that preserves the original logic structure.

            if ($action eq 'start') {
                my $db = $args->{db} // '';
                return {
                    ok      => 1,
                    message => $db ? "Connecting to $db..." : "dbshell ready. Use .connect <file> or provide db on start.",
                };
            }

            if ($action eq 'exec') {
                my $line = $args->{input} // '';
                $line =~ s/^\s+|\s+$//g;
                return { ok => 0, error => "Empty input" } unless $line;

                if ($line =~ /^\.(.*)$/) {
                    my $cmd = $1;
                    my @parts = split /\s+/, $cmd, 2;
                    my $verb = lc(shift @parts);
                    my $arg = $parts[0] // '';

                    if ($verb eq 'help' || $verb eq '?') {
                        return {
                            ok => 1,
                            commands => [
                                { cmd => '.tables',    alias => '.t', desc => 'List all tables' },
                                { cmd => '.describe <table>', alias => '.d', desc => 'Describe table structure' },
                                { cmd => '.indexes <table>',  alias => '.i', desc => 'Show table indexes' },
                                { cmd => '.fkeys <table>',    alias => '.fk', desc => 'Show foreign keys' },
                                { cmd => '.stats <table>',    alias => '.s', desc => 'Table row count and size' },
                                { cmd => '.history',   alias => '.h', desc => 'Show query history' },
                                { cmd => '.export <table>',   alias => '.e', desc => 'Export table to CSV' },
                                { cmd => '.format <fmt>',     alias => '.f', desc => 'Set output format' },
                                { cmd => '.connect <file>',   alias => '.c', desc => 'Connect to database' },
                                { cmd => '.disconnect', desc => 'Disconnect from database' },
                                { cmd => '.help',       alias => '.?', desc => 'Show this help' },
                                { cmd => 'SQL...', desc => 'Execute any SQL query' },
                            ],
                        };
                    }

                    return { ok => 0, error => "Unknown command: .$verb (try .help)" };
                }

                return { ok => 0, error => "No database connected. Use .connect <file> first." };
            }

            if ($action eq 'status') {
                return {
                    ok        => 1,
                    connected => 0,
                    format    => 'table',
                    prompt    => 'db> ',
                };
            }

            if ($action eq 'prompt') {
                my $new_prompt = $args->{prompt} // '';
                return { ok => 1, prompt => $new_prompt };
            }

            return { ok => 0, error => "Unknown action: $action" };
        },
    );
}

1;
