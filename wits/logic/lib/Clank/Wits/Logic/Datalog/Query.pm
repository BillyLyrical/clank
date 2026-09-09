# CLANK-WIT: name=Query
# CLANK-WIT: version=1.0.0
# CLANK-WIT: about=Query a Datalog program: facts + Horn-clause rules with first-order unification and proof search
# CLANK-WIT: usage=Input: { program?: str, goal: str, facts?: [str] } Output: { ok: 1, solutions: [{Var: term, ...}] } or { ok: 0, error: str }
# CLANK-WIT: hint=datalog_query, datalog, query, horn_clause, unification, proof_search
# CLANK-WIT: author=Clank
# CLANK-WIT: license=Artistic-2.0
package Clank::Wits::Logic::Datalog::Query;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'datalog.query',
        description => 'Query a Datalog program: facts + Horn-clause rules with first-order unification and proof search',
        parameters  => {
            type       => 'object',
            properties => {
                program => { type => 'string', description => 'Datalog source program' },
                goal    => { type => 'string', description => 'Goal atom with variables, e.g. gp(alice, Y)' },
                facts   => { type => 'array',  description => 'Extra fact lines appended to the program' },
            },
            required => ['goal'],
        },
        execute => sub {
            my ($args) = @_;
            my $input = $args;
            require Clank::Logic;

            my $program = $input->{program} // '';
            my $goal    = $input->{goal};
            return { ok => 0, error => 'missing goal (e.g. "gp(alice, Y)")' }
                unless defined $goal && length "$goal";

            if ($input->{facts}) {
                my @lines = map { /\G\.\z/ ? $_ : "$_." } @{ $input->{facts} };
                $program .= "\n" . join("\n", grep { length } @lines);
            }

            my $kb = eval { Clank::Logic->parse($program) };
            return { ok => 0, error => "program: $@" } if $@;

            $goal =~ s/\.\z// unless ref $goal;
            my $sols = eval { Clank::Logic->query($kb, ref $goal ? $goal : "$goal") };
            return { ok => 0, error => "query: $@" } if $@;

            return { ok => 1, solutions => [ map { +{ %$_ } } @$sols ] };
        },
    );
}

1;
