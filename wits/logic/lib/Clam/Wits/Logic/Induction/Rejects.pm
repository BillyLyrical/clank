# CLAM-WIT: name=Rejects
# CLAM-WIT: version=1.0.0
# CLAM-WIT: about=Logical rejection — A rejects B (A is incompatible with B)
# CLAM-WIT: usage=Input: { a: true, b: false } Output: { result: true, a: true, b: false, description: "A rejects B" }
# CLAM-WIT: hint=induction_rejects, rejects, incompatible, conflict, mutual_exclusion
# CLAM-WIT: author=CLAM
# CLAM-WIT: license=Artistic-2.0
package Clam::Wits::Logic::Induction::Rejects;
use strict;
use warnings;

my %_state;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'induction.rejects',
        description => 'Logical rejection — A rejects B (A is incompatible with B)',
        parameters  => {
            type       => 'object',
            properties => {
                a => { type => 'any', description => 'Value A' },
                b => { type => 'any', description => 'Value B' },
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

            my $result = ($a != $b) ? 1 : 0;

            my $desc;
            if ($a && !$b) {
                $desc = "A rejects B (A true, B false — conflict)";
            } elsif (!$a && $b) {
                $desc = "B rejects A (B true, A false — conflict)";
            } else {
                $desc = "No conflict (" . ($a ? "both true" : "both false") . ")";
            }

            return {
                result      => $result,
                a           => $a,
                b           => $b,
                conflict    => $result ? 1 : 0,
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
