# CLAM-WIT: name=If
# CLAM-WIT: version=1.0.0
# CLAM-WIT: about=Conditional branching — evaluate a condition and return the appropriate branch
# CLAM-WIT: usage=Input: { condition: "fact_count > 3", then: "strong pattern", else: "weak signal" } Output: { branch: "then"|"else", result: "...", evaluated: true|false }
# CLAM-WIT: hint=induction_if, if, conditional, branching, condition
# CLAM-WIT: author=CLAM
# CLAM-WIT: license=Artistic-2.0
package Clam::Wits::Logic::Induction::If;
use strict;
use warnings;

my %_state;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'induction.if',
        description => 'Conditional branching — evaluate a condition and return the appropriate branch',
        parameters  => {
            type       => 'object',
            properties => {
                condition => { type => 'any',    description => 'Condition to evaluate' },
                then      => { type => 'any',    description => 'Value if condition is true' },
                else      => { type => 'any',    description => 'Value if condition is false' },
            },
            required => ['condition'],
        },
        execute => sub {
            my ($args) = @_;
            my $input = $args;
            my %ctx = (state => \%_state);

            ref $input eq 'HASH' or return { error => "Input must be a hash" };

            my $condition = $input->{condition};
            my $then_val  = $input->{then} // '';
            my $else_val  = $input->{else} // '';

            my $result = _eval_condition($condition, $ctx{state} // {});

            my $branch = $result ? 'then' : 'else';
            my $chosen = $result ? $then_val : $else_val;

            return {
                branch    => $branch,
                result    => $chosen,
                condition => ref $condition eq 'HASH' ? _describe_condition($condition) : "$condition",
                evaluated => $result ? 1 : 0,
            };

            sub _eval_condition {
                my ($cond, $state) = @_;

                return 0 unless defined $cond;

                if (!ref $cond) {
                    return 0 if $cond eq '' || $cond eq '0' || $cond eq 'false';
                    return 1 if $cond eq 'true' || $cond eq '1';
                    return $cond ? 1 : 0;
                }

                if (ref $cond eq 'HASH') {
                    my $value     = $cond->{value};
                    my $op        = $cond->{op} // 'truthy';
                    my $threshold = $cond->{threshold};
                    my $pattern   = $cond->{pattern};
                    my $field     = $cond->{field};
                    my $exists    = $cond->{exists};

                    if (defined $exists) {
                        return exists $state->{$exists} ? 1 : 0;
                    }

                    if (defined $field) {
                        $value = $state->{$field};
                    }

                    if (defined $pattern && defined $value) {
                        my $qr = eval { qr/$pattern/i };
                        return $qr ? ($value =~ $qr ? 1 : 0) : 0;
                    }

                    if (defined $threshold && defined $value) {
                        $value += 0;
                        $threshold += 0;
                        return 1 if $op eq '>'  && $value > $threshold;
                        return 1 if $op eq '>=' && $value >= $threshold;
                        return 1 if $op eq '<'  && $value < $threshold;
                        return 1 if $op eq '<=' && $value <= $threshold;
                        return 1 if $op eq '==' && $value == $threshold;
                        return 1 if $op eq '!=' && $value != $threshold;
                        return 0;
                    }

                    return $value ? 1 : 0;
                }

                if (ref $cond eq 'ARRAY') {
                    return scalar @$cond > 0 ? 1 : 0;
                }

                return $cond ? 1 : 0;
            }

            sub _describe_condition {
                my ($cond) = @_;
                if (defined $cond->{field}) {
                    return "$cond->{field} $cond->{op} $cond->{threshold}" if defined $cond->{threshold};
                    return "$cond->{field} matches $cond->{pattern}" if defined $cond->{pattern};
                    return "exists $cond->{exists}" if defined $cond->{exists};
                }
                return "$cond->{value} $cond->{op} $cond->{threshold}" if defined $cond->{threshold};
                return "truthy";
            }
        },
    );
}

1;
