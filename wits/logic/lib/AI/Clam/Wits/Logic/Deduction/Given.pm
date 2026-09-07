# CLAM-WIT: name=Given
# CLAM-WIT: version=1.0.0
# CLAM-WIT: about=State a given — a specific premise for this case
# CLAM-WIT: usage=Input: { fact: "this code contains strcpy(buf, input)", context: "c/security.wit" } Output: { given_id: 1, fact: "...", certainty: "contingent" }
# CLAM-WIT: hint=deduction_given, given, premise, fact, case
# CLAM-WIT: author=CLAM
# CLAM-WIT: license=Artistic-2.0
package AI::Clam::Wits::Logic::Deduction::Given;
use strict;
use warnings;

my %_state;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'deduction.given',
        description => 'State a given — a specific premise for this case',
        parameters  => {
            type       => 'object',
            properties => {
                fact    => { type => 'string', description => 'The observed fact' },
                context => { type => 'string', description => 'Context where this fact was observed' },
            },
            required => ['fact'],
        },
        execute => sub {
            my ($args) = @_;
            my $input = $args;
            my %ctx = (state => \%_state);

            my $fact = ref $input eq 'HASH' ? ($input->{fact} // '') : $input;
            my $context = ref $input eq 'HASH' ? ($input->{context} // 'direct') : 'direct';

            return { error => "No fact provided" } unless $fact;

            my $state = $ctx{state} // {};
            my $next_id = ($state->{given_count} // 0) + 1;
            $state->{given_count} = $next_id;
            $state->{givens} //= [];
            push @{$state->{givens}}, {
                id        => $next_id,
                fact      => $fact,
                context   => $context,
                certainty => 'contingent',
                timestamp => scalar localtime,
            };

            return {
                given_id  => $next_id,
                fact      => $fact,
                context   => $context,
                certainty => 'contingent',
            };
        },
    );
}

1;
