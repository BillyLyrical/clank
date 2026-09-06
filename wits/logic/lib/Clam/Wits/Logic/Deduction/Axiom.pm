# CLAM-WIT: name=Axiom
# CLAM-WIT: version=1.0.0
# CLAM-WIT: about=State an axiom — an accepted truth requiring no justification
# CLAM-WIT: usage=Input: { truth: "Functions must have no side effects", source: "AGENTS.md" } Output: { axiom_id: 1, truth: "...", certainty: "certain" }
# CLAM-WIT: hint=deduction_axiom, axiom, truth, foundation, accepted
# CLAM-WIT: author=CLAM
# CLAM-WIT: license=Artistic-2.0
package Clam::Wits::Logic::Deduction::Axiom;
use strict;
use warnings;

my %_state;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'deduction.axiom',
        description => 'State an axiom — an accepted truth requiring no justification',
        parameters  => {
            type       => 'object',
            properties => {
                truth  => { type => 'string', description => 'The accepted truth' },
                source => { type => 'string', description => 'Source of the axiom (e.g. AGENTS.md)' },
            },
            required => ['truth'],
        },
        execute => sub {
            my ($args) = @_;
            my $input = $args;
            my %ctx = (state => \%_state);

            my $truth = ref $input eq 'HASH' ? ($input->{truth} // '') : $input;
            my $source = ref $input eq 'HASH' ? ($input->{source} // 'assumed') : 'assumed';

            return { error => "No truth provided" } unless $truth;

            my $state = $ctx{state} // {};
            my $next_id = ($state->{axiom_count} // 0) + 1;
            $state->{axiom_count} = $next_id;
            $state->{axioms} //= [];
            push @{$state->{axioms}}, {
                id        => $next_id,
                truth     => $truth,
                source    => $source,
                certainty => 'certain',
                timestamp => scalar localtime,
            };

            return {
                axiom_id  => $next_id,
                truth     => $truth,
                source    => $source,
                certainty => 'certain',
            };
        },
    );
}

1;
