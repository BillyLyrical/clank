# CLANK-WIT: name=And
# CLANK-WIT: version=1.0.0
# CLANK-WIT: about=Logical AND — all conditions must be truthy
# CLANK-WIT: usage=Input: { conditions: [true, true, false] } or { a: 1, b: 2, c: 3 } Output: { result: false, truthy_count: 2, falsy_count: 1 }
# CLANK-WIT: hint=induction_and, and, logical, conjunction, all_conditions
# CLANK-WIT: author=Clank
# CLANK-WIT: license=Artistic-2.0
package Clank::Wits::Logic::Induction::And;
use strict;
use warnings;

my %_state;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'induction.and',
        description => 'Logical AND — all conditions must be truthy',
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
            my $falsy = 0;
            for my $v (@values) {
                my $t = _to_bool($v);
                if ($t) { $truthy++; }
                else    { $falsy++; last; }
            }

            return {
                result       => $falsy == 0 ? 1 : 0,
                truthy_count => $truthy,
                falsy_count  => $falsy,
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
