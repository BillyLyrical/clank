# CLAM-WIT: name=Maybe
# CLAM-WIT: version=1.0.0
# CLAM-WIT: about=Add uncertainty or qualification to a claim
# CLAM-WIT: usage=Input: { claim: "...", confidence: 0.0-1.0, evidence: [...] } Output: { qualified: "...", confidence: 0.0-1.0, evidence_count: N }
# CLAM-WIT: hint=induction_maybe, maybe, uncertainty, qualification, confidence
# CLAM-WIT: author=CLAM
# CLAM-WIT: license=Artistic-2.0
package AI::Clam::Wits::Logic::Induction::Maybe;
use strict;
use warnings;

my %_state;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'induction.maybe',
        description => 'Add uncertainty or qualification to a claim',
        parameters  => {
            type       => 'object',
            properties => {
                claim      => { type => 'string', description => 'The claim to qualify' },
                confidence => { type => 'number', description => 'Confidence 0.0-1.0' },
                evidence   => { type => 'array',  description => 'Supporting evidence' },
            },
            required => ['claim'],
        },
        execute => sub {
            my ($args) = @_;
            my $input = $args;
            my %ctx = (state => \%_state);

            my $claim      = ref $input eq 'HASH' ? ($input->{claim} // '') : $input;
            my $confidence = ref $input eq 'HASH' ? ($input->{confidence} // 0.5) : 0.5;
            my $evidence   = ref $input eq 'HASH' ? ($input->{evidence} // []) : [];

            return { error => "No claim provided" } unless $claim;

            my $state = $ctx{state} // {};
            my $next_id = ($state->{maybe_count} // 0) + 1;
            $state->{maybe_count} = $next_id;
            $state->{qualifications} //= [];
            push @{$state->{qualifications}}, {
                id         => $next_id,
                claim      => $claim,
                confidence => $confidence,
                evidence   => $evidence,
                timestamp  => scalar localtime,
            };

            my $qualifier;
            if ($confidence >= 0.9) {
                $qualifier = "almost certainly";
            } elsif ($confidence >= 0.7) {
                $qualifier = "likely";
            } elsif ($confidence >= 0.5) {
                $qualifier = "possibly";
            } elsif ($confidence >= 0.3) {
                $qualifier = "unlikely";
            } else {
                $qualifier = "improbable";
            }

            return {
                maybe_id       => $next_id,
                qualified      => "$qualifier: $claim",
                confidence     => $confidence,
                evidence_count => scalar @$evidence,
                claim          => $claim,
            };
        },
    );
}

1;
