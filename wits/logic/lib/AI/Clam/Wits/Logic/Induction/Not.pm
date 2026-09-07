# CLAM-WIT: name=Not
# CLAM-WIT: version=1.0.0
# CLAM-WIT: about=Negate a value or condition
# CLAM-WIT: usage=Input: { value: true } or { value: 0 } Output: { negated: false, original: true, type: "boolean" }
# CLAM-WIT: hint=induction_not, not, negate, logical, negation
# CLAM-WIT: author=CLAM
# CLAM-WIT: license=Artistic-2.0
package AI::Clam::Wits::Logic::Induction::Not;
use strict;
use warnings;

my %_state;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'induction.not',
        description => 'Negate a value or condition',
        parameters  => {
            type       => 'object',
            properties => {
                value => { type => 'any', description => 'Value to negate' },
            },
        },
        execute => sub {
            my ($args) = @_;
            my $input = $args;
            my %ctx = (state => \%_state);

            my $value = ref $input eq 'HASH' ? ($input->{value} // 0) : $input;

            my ($negated, $type);

            if (!ref $value && ($value eq 'true' || $value eq '1')) {
                $negated = 0;
                $type = 'boolean';
            } elsif (!ref $value && ($value eq 'false' || $value eq '0' || $value eq '')) {
                $negated = 1;
                $type = 'boolean';
            } elsif (ref $value eq 'ARRAY') {
                $negated = scalar @$value == 0 ? 1 : 0;
                $type = 'array';
            } elsif (ref $value eq 'HASH') {
                $negated = scalar keys %$value == 0 ? 1 : 0;
                $type = 'hash';
            } else {
                $negated = $value ? 0 : 1;
                $type = 'truthy';
            }

            return {
                negated  => $negated,
                original => $value,
                type     => $type,
            };
        },
    );
}

1;
