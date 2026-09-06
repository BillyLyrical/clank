# CLAM-WIT: name=Rule
# CLAM-WIT: version=1.0.0
# CLAM-WIT: about=State an inference rule — if P then Q
# CLAM-WIT: usage=Input: { if: "code contains strcpy", then: "potential buffer overflow", name: "strcpy_overflow" } Output: { rule_id: 1, if: "...", then: "...", valid: true }
# CLAM-WIT: hint=deduction_rule, inference, rule, if_then, implication
# CLAM-WIT: author=CLAM
# CLAM-WIT: license=Artistic-2.0
package Clam::Wits::Logic::Deduction::Rule;
use strict;
use warnings;

my %_state;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'deduction.rule',
        description => 'State an inference rule — if P then Q',
        parameters  => {
            type       => 'object',
            properties => {
                if   => { type => 'string', description => 'The antecedent (condition)' },
                then => { type => 'string', description => 'The consequent (conclusion)' },
                name => { type => 'string', description => 'Name for this rule' },
                valid => { type => 'boolean', description => 'Whether this rule is valid (default: true)' },
            },
            required => ['if', 'then'],
        },
        execute => sub {
            my ($args) = @_;
            my $input = $args;
            my %ctx = (state => \%_state);

            my $if_part = ref $input eq 'HASH' ? ($input->{if} // '') : '';
            my $then_part = ref $input eq 'HASH' ? ($input->{then} // '') : '';
            my $name = ref $input eq 'HASH' ? ($input->{name} // 'unnamed') : 'unnamed';
            my $valid = ref $input eq 'HASH' ? ($input->{valid} // 1) : 1;

            return { error => "Rule requires 'if' and 'then'" } unless $if_part && $then_part;

            my $state = $ctx{state} // {};
            my $next_id = ($state->{rule_count} // 0) + 1;
            $state->{rule_count} = $next_id;
            $state->{rules} //= [];
            push @{$state->{rules}}, {
                id        => $next_id,
                if_part   => $if_part,
                then_part => $then_part,
                name      => $name,
                valid     => $valid,
                timestamp => scalar localtime,
            };

            return {
                rule_id => $next_id,
                if_part => $if_part,
                then_part => $then_part,
                name    => $name,
                valid   => $valid,
            };
        },
    );
}

1;
