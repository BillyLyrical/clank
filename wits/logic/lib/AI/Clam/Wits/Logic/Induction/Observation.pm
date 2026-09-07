# CLAM-WIT: name=Observation
# CLAM-WIT: version=1.0.0
# CLAM-WIT: about=Record a meta-observation about the reasoning process
# CLAM-WIT: usage=Input: { about: "the pattern repeats across modules", insight: "This suggests a systemic issue" } Output: { observation_id: 1, about: "...", insight: "..." }
# CLAM-WIT: hint=induction_observation, observation, meta, insight, reasoning
# CLAM-WIT: author=CLAM
# CLAM-WIT: license=Artistic-2.0
package AI::Clam::Wits::Logic::Induction::Observation;
use strict;
use warnings;

my %_state;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'induction.observation',
        description => 'Record a meta-observation about the reasoning process',
        parameters  => {
            type       => 'object',
            properties => {
                about   => { type => 'string', description => 'What the observation is about' },
                insight => { type => 'string', description => 'The insight gained' },
            },
        },
        execute => sub {
            my ($args) = @_;
            my $input = $args;
            my %ctx = (state => \%_state);

            my $about   = ref $input eq 'HASH' ? ($input->{about} // '') : '';
            my $insight = ref $input eq 'HASH' ? ($input->{insight} // $input) : $input;

            return { error => "No observation provided" } unless $about || $insight;

            my $state = $ctx{state} // {};
            my $next_id = ($state->{observation_count} // 0) + 1;
            $state->{observation_count} = $next_id;
            $state->{observations} //= [];
            push @{$state->{observations}}, {
                id        => $next_id,
                about     => $about,
                insight   => $insight,
                timestamp => scalar localtime,
            };

            return {
                observation_id => $next_id,
                about          => $about,
                insight        => $insight,
            };
        },
    );
}

1;
