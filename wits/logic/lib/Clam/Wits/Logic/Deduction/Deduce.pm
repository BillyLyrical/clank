# CLAM-WIT: name=Deduce
# CLAM-WIT: version=1.0.0
# CLAM-WIT: about=Orchestrate a full deductive chain — axioms + givens through rules to conclusion
# CLAM-WIT: usage=Input: { axioms: [...], givens: [...], rules: [...], contrapositives: [...] } Output: { conclusion: "...", proof: [...], valid: true, certainty: "..." }
# CLAM-WIT: hint=deduction_deduce, deduce, chain, orchestrate, full_deduction
# CLAM-WIT: author=CLAM
# CLAM-WIT: license=Artistic-2.0
package Clam::Wits::Logic::Deduction::Deduce;
use strict;
use warnings;

my %_state;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'deduction.deduce',
        description => 'Orchestrate a full deductive chain — axioms + givens through rules to conclusion',
        parameters  => {
            type       => 'object',
            properties => {
                axioms          => { type => 'array', description => 'Array of axiom records' },
                givens          => { type => 'array', description => 'Array of given facts' },
                rules           => { type => 'array', description => 'Array of inference rules' },
                contrapositives => { type => 'array', description => 'Array of contrapositive records' },
            },
            required => ['rules'],
        },
        execute => sub {
            my ($args) = @_;
            my $input = $args;
            my %ctx = (state => \%_state);

            my $axioms = ref $input eq 'HASH' ? ($input->{axioms} // []) : [];
            my $givens = ref $input eq 'HASH' ? ($input->{givens} // []) : [];
            my $rules = ref $input eq 'HASH' ? ($input->{rules} // []) : [];
            my $contras = ref $input eq 'HASH' ? ($input->{contrapositives} // []) : [];
            my $wits = $ctx{wits};

            return { error => "No rules provided" } unless @$rules;

            my @proof_steps;
            my $overall_valid = 1;
            my $overall_certainty = 'certain';
            my $conclusion = '';

            for my $axiom (@$axioms) {
                my $result = eval { $wits->execute('deduction.axiom', $axiom, %ctx) } if $wits;
                if ($result) {
                    push @proof_steps, { %$result, _type => 'axiom' };
                }
            }

            for my $given (@$givens) {
                my $result = eval { $wits->execute('deduction.given', $given, %ctx) } if $wits;
                if ($result) {
                    push @proof_steps, { %$result, _type => 'given' };
                    if (($result->{certainty} // 'contingent') ne 'certain') {
                        $overall_certainty = 'contingent';
                    }
                }
            }

            for my $rule (@$rules) {
                my $result = eval { $wits->execute('deduction.rule', $rule, %ctx) } if $wits;
                if ($result) {
                    push @proof_steps, { %$result, _type => 'rule' };
                }
            }

            for my $rule (@$rules) {
                my $apply_input = {
                    rule      => $rule,
                    premises  => [@$axioms, @$givens],
                };
                my $result = eval { $wits->execute('deduction.apply', $apply_input, %ctx) } if $wits;
                if ($result) {
                    push @proof_steps, { %$result, _type => 'apply' };
                    if ($result->{valid} && $result->{conclusion}) {
                        $conclusion = $result->{conclusion};
                        my $cert = $result->{certainty} // 'contingent';
                        if ($cert eq 'impossible') {
                            $overall_valid = 0;
                            $overall_certainty = 'impossible';
                        } elsif ($cert eq 'contingent' && $overall_certainty ne 'impossible') {
                            $overall_certainty = 'contingent';
                        }
                    }
                }
            }

            for my $contra (@$contras) {
                my $result = eval { $wits->execute('deduction.contrapositive', $contra, %ctx) } if $wits;
                if ($result) {
                    push @proof_steps, { %$result, _type => 'contrapositive' };
                    if ($result->{refuted}) {
                        $conclusion = "REFUTED: $conclusion";
                        $overall_valid = 0;
                    }
                }
            }

            my $cert_result = eval { $wits->execute('deduction.certainty', {
                claim    => $conclusion,
                level    => $overall_certainty,
                premises => [@$axioms, @$givens],
            }, %ctx) } if $wits;
            if ($cert_result) {
                push @proof_steps, { %$cert_result, _type => 'certainty' };
                $overall_certainty = $cert_result->{level};
            }

            my $proof_result = eval { $wits->execute('deduction.proof', {
                steps      => \@proof_steps,
                conclusion => $conclusion,
            }, %ctx) } if $wits;

            return {
                conclusion  => $conclusion || 'No conclusion reached',
                proof       => $proof_result->{steps} // \@proof_steps,
                valid       => $overall_valid,
                certainty   => $overall_certainty,
                axiom_count => scalar @$axioms,
                given_count => scalar @$givens,
                rule_count  => scalar @$rules,
                step_count  => scalar @proof_steps,
            };
        },
    );
}

1;
