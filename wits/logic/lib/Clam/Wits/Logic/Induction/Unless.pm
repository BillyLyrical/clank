# CLAM-WIT: name=Unless
# CLAM-WIT: version=1.0.0
# CLAM-WIT: about=Execute the else branch when a condition is falsy
# CLAM-WIT: usage=Input: { condition: false, unless: "fallback value" } Output: { triggered: true|false, result: "...", condition: "..." }
# CLAM-WIT: hint=induction_unless, unless, fallback, negated_condition
# CLAM-WIT: author=CLAM
# CLAM-WIT: license=Artistic-2.0
package Clam::Wits::Logic::Induction::Unless;
use strict;
use warnings;

my %_state;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'induction.unless',
        description => 'Execute the else branch when a condition is falsy',
        parameters  => {
            type       => 'object',
            properties => {
                condition => { type => 'any',    description => 'Condition to evaluate' },
                unless    => { type => 'any',    description => 'Value if condition is falsy' },
            },
            required => ['condition', 'unless'],
        },
        execute => sub {
            my ($args) = @_;
            my $input = $args;
            my %ctx = (state => \%_state);

            ref $input eq 'HASH' or return { error => "Input must be a hash" };

            my $condition  = $input->{condition};
            my $unless_val = $input->{unless} // '';

            my $cond_true = _eval_condition($condition, $ctx{state} // {});

            my $triggered = $cond_true ? 0 : 1;
            my $result = $triggered ? $unless_val : undef;

            return {
                triggered => $triggered,
                result    => $result,
                condition => ref $condition eq 'HASH' ? _describe_condition($condition) : "$condition",
            };

            sub _eval_condition {
                my ($cond, $state) = @_;
                return 0 unless defined $cond;
                return 1 if !ref $cond && $cond eq 'true';
                return 0 if !ref $cond && $cond eq 'false';
                return $cond ? 1 : 0 if !ref $cond;
                if (ref $cond eq 'HASH') {
                    my $value     = $cond->{value};
                    my $op        = $cond->{op} // 'truthy';
                    my $threshold = $cond->{threshold};
                    my $field     = $cond->{field};
                    my $exists    = $cond->{exists};
                    my $pattern   = $cond->{pattern};
                    if (defined $exists) { return exists $state->{$exists} ? 1 : 0; }
                    if (defined $field) { $value = $state->{$field}; }
                    if (defined $pattern && defined $value) {
                        my $qr = eval { qr/$pattern/i };
                        return $qr ? ($value =~ $qr ? 1 : 0) : 0;
                    }
                    if (defined $threshold && defined $value) {
                        $value += 0; $threshold += 0;
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
                if (ref $cond eq 'ARRAY') { return scalar @$cond > 0 ? 1 : 0; }
                return 0;
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
