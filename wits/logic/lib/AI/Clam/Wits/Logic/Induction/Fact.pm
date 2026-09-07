# CLAM-WIT: name=Fact
# CLAM-WIT: version=1.0.0
# CLAM-WIT: about=State a fact — an observation, data point, or measurement
# CLAM-WIT: usage=Input: { data: "module X has 500 lines", source: "wc -l" } Output: { fact_id: 1, data: "...", source: "...", timestamp: "..." }
# CLAM-WIT: hint=induction_fact, fact, observation, data, measurement
# CLAM-WIT: author=CLAM
# CLAM-WIT: license=Artistic-2.0
package AI::Clam::Wits::Logic::Induction::Fact;
use strict;
use warnings;

my %_state;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'induction.fact',
        description => 'State a fact — an observation, data point, or measurement',
        parameters  => {
            type       => 'object',
            properties => {
                data   => { type => 'string', description => 'The observed data or fact' },
                source => { type => 'string', description => 'Source of the fact' },
                weight => { type => 'number', description => 'Weight of the fact' },
            },
            required => ['data'],
        },
        execute => sub {
            my ($args) = @_;
            my $input = $args;
            my %ctx = (state => \%_state);

            my $data   = ref $input eq 'HASH' ? ($input->{data} // '') : $input;
            my $source = ref $input eq 'HASH' ? ($input->{source} // 'direct') : 'direct';
            my $weight = ref $input eq 'HASH' ? ($input->{weight} // 1.0) : 1.0;

            return { error => "No data provided" } unless $data;

            my $state = $ctx{state} // {};
            my $next_id = ($state->{fact_count} // 0) + 1;
            $state->{fact_count} = $next_id;
            $state->{facts} //= [];
            push @{$state->{facts}}, {
                id        => $next_id,
                data      => $data,
                source    => $source,
                weight    => $weight,
                timestamp => scalar localtime,
            };

            return {
                fact_id   => $next_id,
                data      => $data,
                source    => $source,
                weight    => $weight,
                timestamp => $state->{facts}[-1]{timestamp},
            };
        },
    );
}

1;
