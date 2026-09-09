# CLANK-WIT: name=Certainty
# CLANK-WIT: version=1.0.0
# CLANK-WIT: about=Mark or propagate certainty through a derivation chain
# CLANK-WIT: usage=Input: { claim: "code is safe", level: "certain" } Output: { certified: "code is safe", level: "certain", valid: true }
# CLANK-WIT: hint=deduction_certainty, certainty, confidence, propagation, levels
# CLANK-WIT: author=Clank
# CLANK-WIT: license=Artistic-2.0
package Clank::Wits::Logic::Deduction::Certainty;
use strict;
use warnings;

my %_state;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'deduction.certainty',
        description => 'Mark or propagate certainty through a derivation chain',
        parameters  => {
            type       => 'object',
            properties => {
                claim    => { type => 'string', description => 'The claim to certify' },
                level    => { type => 'string', description => 'Certainty level: certain, contingent, impossible' },
                premises => { type => 'array',  description => 'Premises to propagate certainty from' },
            },
            required => ['claim'],
        },
        execute => sub {
            my ($args) = @_;
            my $input = $args;
            my %ctx = (state => \%_state);

            my $claim = ref $input eq 'HASH' ? ($input->{claim} // '') : $input;
            my $level = ref $input eq 'HASH' ? ($input->{level} // 'contingent') : 'contingent';
            my $premises = ref $input eq 'HASH' ? ($input->{premises} // []) : [];

            return { error => "No claim provided" } unless $claim;

            my %valid_levels = (certain => 1, contingent => 1, impossible => 1);
            unless ($valid_levels{$level}) {
                return { error => "Invalid certainty level: $level (use certain/contingent/impossible)" };
            }

            if (@$premises) {
                my $weakest = 'certain';
                for my $p (@$premises) {
                    my $cert = ref $p eq 'HASH' ? ($p->{certainty} // 'contingent') : 'contingent';
                    if ($cert eq 'impossible') {
                        $weakest = 'impossible';
                        last;
                    } elsif ($cert eq 'contingent' && $weakest ne 'impossible') {
                        $weakest = 'contingent';
                    }
                }
                $level = $weakest;
            }

            my $valid = ($level eq 'certain') ? 1 : ($level eq 'impossible' ? 0 : 1);

            my $state = $ctx{state} // {};
            my $next_id = ($state->{certainty_count} // 0) + 1;
            $state->{certainty_count} = $next_id;
            $state->{certainties} //= [];
            push @{$state->{certainties}}, {
                id        => $next_id,
                claim     => $claim,
                level     => $level,
                valid     => $valid,
                timestamp => scalar localtime,
            };

            return {
                certainty_id => $next_id,
                certified    => $claim,
                level        => $level,
                valid        => $valid,
            };
        },
    );
}

1;
