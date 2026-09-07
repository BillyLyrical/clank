# CLAM-WIT: name=Apply
# CLAM-WIT: version=1.0.0
# CLAM-WIT: about=Apply a rule to premises — derive a conclusion
# CLAM-WIT: usage=Input: { rule: { if: "code has strcpy", then: "overflow risk" }, premises: [{ fact: "code has strcpy(buf, input)" }] } Output: { conclusion: "overflow risk", certainty: "contingent", valid: true }
# CLAM-WIT: hint=deduction_apply, apply, derive, conclusion, modus_ponens
# CLAM-WIT: author=CLAM
# CLAM-WIT: license=Artistic-2.0
package AI::Clam::Wits::Logic::Deduction::Apply;
use strict;
use warnings;

my %_state;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'deduction.apply',
        description => 'Apply a rule to premises — derive a conclusion',
        parameters  => {
            type       => 'object',
            properties => {
                rule      => { type => 'object', description => 'The inference rule { if, then }' },
                premises  => { type => 'array',  description => 'Array of premise facts' },
                conclusion => { type => 'string', description => 'Explicit conclusion (overrides rule then-part)' },
            },
            required => ['rule', 'premises'],
        },
        execute => sub {
            my ($args) = @_;
            my $input = $args;
            my %ctx = (state => \%_state);

            my $rule = ref $input eq 'HASH' ? ($input->{rule} // {}) : {};
            my $premises = ref $input eq 'HASH' ? ($input->{premises} // []) : [];
            my $conclusion = ref $input eq 'HASH' ? ($input->{conclusion} // '') : '';

            my $if_part = ref $rule eq 'HASH' ? ($rule->{if_part} // $rule->{if} // '') : '';
            my $then_part = ref $rule eq 'HASH' ? ($rule->{then_part} // $rule->{then} // '') : '';
            my $rule_valid = ref $rule eq 'HASH' ? ($rule->{valid} // 1) : 1;

            return { error => "Rule requires 'if' and 'then'" } unless $if_part && $then_part;

            my $premise_facts = join(' ', map { ref $_ eq 'HASH' ? ($_->{fact} // $_->{data} // '') : "$_" } @$premises);
            my $premise_certain = 'certain';
            for my $p (@$premises) {
                my $cert = ref $p eq 'HASH' ? ($p->{certainty} // 'contingent') : 'contingent';
                if ($cert ne 'certain') {
                    $premise_certain = 'contingent';
                    last;
                }
            }

            my $matched = ($premise_facts && $if_part) ?
                ($premise_facts =~ /\Q$if_part\E/i ? 1 : ($premise_facts =~ $if_part ? 1 : 0)) : 0;

            my $result_certainty = 'impossible';
            if ($matched && $rule_valid) {
                $result_certainty = $premise_certain;
            } elsif ($matched && !$rule_valid) {
                $result_certainty = 'impossible';
            }

            my $derived = $conclusion || ($matched ? $then_part : undef);

            my $state = $ctx{state} // {};
            my $next_id = ($state->{apply_count} // 0) + 1;
            $state->{apply_count} = $next_id;
            $state->{derivations} //= [];
            push @{$state->{derivations}}, {
                id          => $next_id,
                rule        => $rule,
                premises    => $premises,
                conclusion  => $derived,
                certainty   => $result_certainty,
                matched     => $matched,
                valid       => $matched && $rule_valid,
                timestamp   => scalar localtime,
            };

            return {
                apply_id    => $next_id,
                conclusion  => $derived,
                certainty   => $result_certainty,
                matched     => $matched,
                valid       => $matched && $rule_valid,
                rule_valid  => $rule_valid,
            };
        },
    );
}

1;
