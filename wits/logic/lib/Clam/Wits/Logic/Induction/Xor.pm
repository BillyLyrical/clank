# CLAM-WIT: name=Xor
# CLAM-WIT: version=1.0.0
# CLAM-WIT: about=Logical XOR — exactly one condition must be truthy
# CLAM-WIT: usage=Input: { conditions: [true, false] } or { a: 1, b: 0 } Output: { result: true, truthy_count: 1, count: 2 }
# CLAM-WIT: hint=induction_xor, xor, exclusive, logical, mutual_exclusion
# CLAM-WIT: author=CLAM
# CLAM-WIT: license=Artistic-2.0
package Clam::Wits::Logic::Induction::Xor;
use strict;
use warnings;

my %_state;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'induction.xor',
        description => 'Logical XOR — exactly one condition must be truthy',
        parameters  => {
            type       => 'object',
            properties => {
                conditions => { type => 'array',  description => 'Array of truthy/falsy values' },
                value      => { type => 'any',    description => 'Single condition value' },
            },
        },
        execute => sub {
            my ($args) = @_;
            my $input = $args;
            my %ctx = (state => \%_state);

            ref $input eq 'HASH' or return { error => "Input must be a hash" };

            my @values;

            if (ref $input->{conditions} eq 'ARRAY') {
                @values = @{$input->{conditions}};
            }
            elsif (exists $input->{a}) {
                for my $k (sort keys %$input) {
                    next if $k eq 'error';
                    push @values, $input->{$k};
                }
            }
            else {
                @values = ($input->{value} // 0);
            }

            my $truthy = 0;
            for my $v (@values) {
                $truthy++ if _to_bool($v);
            }

            my $result = $truthy == 1 ? 1 : 0;

            return {
                result       => $result,
                truthy_count => $truthy,
                falsy_count  => scalar(@values) - $truthy,
                count        => scalar @values,
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
