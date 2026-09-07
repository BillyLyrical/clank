# CLAM-WIT: name=Proof
# CLAM-WIT: version=1.0.0
# CLAM-WIT: about=Record and validate a proof — the derivation path with logical form
# CLAM-WIT: usage=Input: { steps: [...], conclusion: "..." } Output: { proof_id: 1, steps: [...], valid: true, length: N }
# CLAM-WIT: hint=deduction_proof, proof, derivation, trace, validation
# CLAM-WIT: author=CLAM
# CLAM-WIT: license=Artistic-2.0
package AI::Clam::Wits::Logic::Deduction::Proof;
use strict;
use warnings;

my %_state;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'deduction.proof',
        description => 'Record and validate a proof — the derivation path with logical form',
        parameters  => {
            type       => 'object',
            properties => {
                steps      => { type => 'array',  description => 'Array of proof step records' },
                conclusion => { type => 'string', description => 'The final conclusion of the proof' },
            },
            required => ['steps'],
        },
        execute => sub {
            my ($args) = @_;
            my $input = $args;
            my %ctx = (state => \%_state);

            my $steps = ref $input eq 'HASH' ? ($input->{steps} // []) : [];
            my $conclusion = ref $input eq 'HASH' ? ($input->{conclusion} // '') : '';

            return { error => "No steps provided" } unless @$steps;

            my $valid = 1;
            my @trace;
            for my $i (0 .. $#$steps) {
                my $step = $steps->[$i];
                my $type = $step->{_type} // $step->{type} // 'unknown';
                my $certainty = $step->{certainty} // 'contingent';

                my %entry = (
                    step        => $i + 1,
                    type        => $type,
                    certainty   => $certainty,
                );

                if ($type eq 'axiom') {
                    $entry{form} = "AXIOM: " . ($step->{truth} // $step->{data} // '');
                } elsif ($type eq 'rule') {
                    $entry{form} = "RULE: IF " . ($step->{if_part} // $step->{if} // '') .
                                   " THEN " . ($step->{then_part} // $step->{then} // '');
                } elsif ($type eq 'given') {
                    $entry{form} = "GIVEN: " . ($step->{fact} // $step->{data} // '');
                } elsif ($type eq 'apply') {
                    $entry{form} = "DERIVE: " . ($step->{conclusion} // '');
                    $entry{valid} = $step->{valid} // 1;
                    $valid = 0 unless $entry{valid};
                } elsif ($type eq 'contrapositive') {
                    $entry{form} = "REFUTE: " . ($step->{premise_false} // '');
                    $entry{valid} = $step->{valid} // 1;
                } else {
                    $entry{form} = "STEP: " . ($step->{conclusion} // $step->{data} // $step->{fact} // 'unknown');
                }

                if ($certainty eq 'impossible') {
                    $valid = 0;
                }

                push @trace, \%entry;
            }

            my $state = $ctx{state} // {};
            my $next_id = ($state->{proof_count} // 0) + 1;
            $state->{proof_count} = $next_id;
            $state->{proofs} //= [];
            push @{$state->{proofs}}, {
                id         => $next_id,
                trace      => \@trace,
                conclusion => $conclusion,
                valid      => $valid,
                length     => scalar @trace,
                timestamp  => scalar localtime,
            };

            return {
                proof_id   => $next_id,
                steps      => \@trace,
                conclusion => $conclusion,
                valid      => $valid,
                length     => scalar @trace,
            };
        },
    );
}

1;
