# CLAM-WIT: name=Contrapositive
# CLAM-WIT: version=1.0.0
# CLAM-WIT: about=Refute by contradiction — if conclusion is false, premise must be false
# CLAM-WIT: usage=Input: { rule: { if: "code has strcpy", then: "overflow risk" }, conclusion_negated: true } Output: { refuted: true, premise_false: "...", valid: true }
# CLAM-WIT: hint=deduction_contrapositive, contrapositive, refutation, modus_tollens, contradiction
# CLAM-WIT: author=CLAM
# CLAM-WIT: license=Artistic-2.0
package Clam::Wits::Logic::Deduction::Contrapositive;
use strict;
use warnings;

my %_state;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'deduction.contrapositive',
        description => 'Refute by contradiction — if conclusion is false, premise must be false',
        parameters  => {
            type       => 'object',
            properties => {
                rule                => { type => 'object', description => 'The inference rule { if, then }' },
                conclusion_negated  => { type => 'boolean', description => 'Whether the conclusion is negated' },
                actual_conclusion   => { type => 'string', description => 'The actual conclusion value (set to "false" to negate)' },
            },
            required => ['rule'],
        },
        execute => sub {
            my ($args) = @_;
            my $input = $args;
            my %ctx = (state => \%_state);

            my $rule = ref $input eq 'HASH' ? ($input->{rule} // {}) : {};
            my $conclusion_negated = ref $input eq 'HASH' ? ($input->{conclusion_negated} // 0) : 0;
            my $actual_conclusion = ref $input eq 'HASH' ? ($input->{actual_conclusion} // '') : '';

            my $if_part = ref $rule eq 'HASH' ? ($rule->{if_part} // $rule->{if} // '') : '';
            my $then_part = ref $rule eq 'HASH' ? ($rule->{then_part} // $rule->{then} // '') : '';

            return { error => "Rule requires 'if' and 'then'" } unless $if_part && $then_part;

            my $refuted = 0;
            my $premise_false = '';
            my $valid = 0;

            if ($conclusion_negated || ($actual_conclusion && $actual_conclusion eq 'false')) {
                $refuted = 1;
                $premise_false = "NOT: $if_part (because NOT: $then_part)";
                $valid = 1;
            } elsif ($actual_conclusion && $actual_conclusion ne 'false') {
                $refuted = 0;
                $premise_false = "Cannot refute: conclusion '$actual_conclusion' is not negated";
                $valid = 0;
            } else {
                $refuted = 0;
                $premise_false = "No negation provided — contrapositive requires \x{00ac}Q";
                $valid = 0;
            }

            my $state = $ctx{state} // {};
            my $next_id = ($state->{contra_count} // 0) + 1;
            $state->{contra_count} = $next_id;
            $state->{refutations} //= [];
            push @{$state->{refutations}}, {
                id             => $next_id,
                rule           => $rule,
                refuted        => $refuted,
                premise_false  => $premise_false,
                valid          => $valid,
                timestamp      => scalar localtime,
            };

            return {
                contrapositive_id => $next_id,
                refuted           => $refuted,
                premise_false     => $premise_false,
                valid             => $valid,
                modus_tollens     => $refuted ? "\x{00ac}Q ($then_part) \x{2192} \x{00ac}P ($if_part)" : undef,
            };
        },
    );
}

1;
