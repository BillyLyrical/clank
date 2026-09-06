# CLAM-WIT: name=Implies
# CLAM-WIT: version=1.0.0
# CLAM-WIT: about=Logical implication — if A then B (A implies B)
# CLAM-WIT: usage=Input: { a: true, b: true } Output: { result: true, a: true, b: true, description: "true -> true = true" }
# CLAM-WIT: hint=induction_implies, implies, implication, conditional, material_implication
# CLAM-WIT: author=CLAM
# CLAM-WIT: license=Artistic-2.0
package Clam::Wits::Logic::Induction::Implies;
use strict;
use warnings;

my %_state;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'induction.implies',
        description => 'Logical implication — if A then B (A implies B)',
        parameters  => {
            type       => 'object',
            properties => {
                a => { type => 'any', description => 'Antecedent (A)' },
                b => { type => 'any', description => 'Consequent (B)' },
            },
            required => ['a', 'b'],
        },
        execute => sub {
            my ($args) = @_;
            my $input = $args;
            my %ctx = (state => \%_state);

            ref $input eq 'HASH' or return { error => "Input must be a hash" };

            my $a = _to_bool($input->{a} // 0);
            my $b = _to_bool($input->{b} // 0);

            my $result = (!$a || $b) ? 1 : 0;

            my $desc = ($a ? "true" : "false") . " -> " . ($b ? "true" : "false") . " = " . ($result ? "true" : "false");

            return {
                result      => $result,
                a           => $a,
                b           => $b,
                description => $desc,
            };

            sub _to_bool {
                my $v = shift;
                return 0 unless defined $v;
                return 0 if !ref $v && ($v eq '' || $v eq '0' || $v eq 'false');
                return 1 if ref $v eq 'ARRAY';
                return 1 if ref $v eq 'HASH' && keys %$v;
                return $v ? 1 : 0;
            }
        },
    );
}

1;
