# CLANK-WIT: name=Encode
# CLANK-WIT: version=1.0.0
# CLANK-WIT: about=Encode constraints into DIMACS CNF format
# CLANK-WIT: usage=Input: { variables: { A: [1,2,3], B: [1,2,3] }, constraints: [...] } Output: { ok: true, dimacs: "p cnf 6 5\n...", vars: {...}, num_vars: 6, num_clauses: 5 }
# CLANK-WIT: hint=sat_encode, encode, cnf, dimacs, constraints, variables
# CLANK-WIT: author=Clank
# CLANK-WIT: license=Artistic-2.0
package Clank::Wits::Logic::Sat::Encode;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'sat.encode',
        description => 'Encode constraints into DIMACS CNF format',
        parameters  => {
            type       => 'object',
            properties => {
                variables   => { type => 'object', description => 'Variable domains: { name: [values] }' },
                constraints => { type => 'array',  description => 'Constraint specifications' },
                bool_vars   => { type => 'array',  description => 'Boolean variable names' },
            },
            required => [],
        },
        execute => sub {
            my ($args) = @_;
            my $input = $args;
            my $vars_def   = ref $input eq 'HASH' ? ($input->{variables}  // {}) : {};
            my $constraints= ref $input eq 'HASH' ? ($input->{constraints}// []) : [];
            my $bool_vars  = ref $input eq 'HASH' ? ($input->{bool_vars} // []) : [];

            my %var_map;
            my $next_var = 1;
            my @clauses;

            for my $bv (@$bool_vars) {
                $var_map{$bv}{1} = $next_var++;
            }

            for my $vname (sort keys %$vars_def) {
                my $domain = $vars_def->{$vname};
                next unless ref $domain eq 'ARRAY' && @$domain;

                for my $val (@$domain) {
                    $var_map{$vname}{$val} = $next_var++;
                }

                my @sv = map { $var_map{$vname}{$_} } @$domain;
                for my $i (0..$#sv) {
                    for my $j ($i+1..$#sv) {
                        push @clauses, [-$sv[$i], -$sv[$j]];
                    }
                }

                push @clauses, [@sv];
            }

            for my $c (@$constraints) {
                my $type = $c->{type} // 'clause';

                if ($type eq 'clause') {
                    my @lits;
                    for my $lit (@{$c->{literals} // []}) {
                        my $neg = ($lit =~ s/^!//);
                        if ($lit =~ /^(\w+)=(.+)$/) {
                            my ($vn, $val) = ($1, $2);
                            return { error => "Variable '$vn' value '$val' not in domain" } unless exists $var_map{$vn}{$val};
                            my $sv = $var_map{$vn}{$val};
                            push @lits, $neg ? -$sv : $sv;
                        } elsif ($lit =~ /^\d+$/) {
                            push @lits, $neg ? -$lit : $lit;
                        }
                    }
                    push @clauses, [@lits] if @lits;
                }

                elsif ($type eq 'atleast') {
                    my $k = $c->{k} // 1;
                    my @lits;
                    for my $lit (@{$c->{literals} // []}) {
                        if ($lit =~ /^(\w+)=(.+)$/) {
                            my ($vn, $val) = ($1, $2);
                            return { error => "Unknown: $vn=$val" } unless exists $var_map{$vn}{$val};
                            push @lits, $var_map{$vn}{$val};
                        }
                    }
                    if (@lits >= $k) {
                        my @combos = _combinations(\@lits, $k - 1);
                        for my $combo (@combos) {
                            push @clauses, [map { -$_ } @$combo];
                        }
                    }
                }

                elsif ($type eq 'atmost') {
                    my $k = $c->{k} // 1;
                    my @lits;
                    for my $lit (@{$c->{literals} // []}) {
                        if ($lit =~ /^(\w+)=(.+)$/) {
                            my ($vn, $val) = ($1, $2);
                            return { error => "Unknown: $vn=$val" } unless exists $var_map{$vn}{$val};
                            push @lits, $var_map{$vn}{$val};
                        }
                    }
                    if (@lits > $k) {
                        my @combos = _combinations(\@lits, $k + 1);
                        for my $combo (@combos) {
                            push @clauses, [map { -$_ } @$combo];
                        }
                    }
                }

                elsif ($type eq 'exactly') {
                    my $k = $c->{k} // 1;
                    my @lits;
                    for my $lit (@{$c->{literals} // []}) {
                        if ($lit =~ /^(\w+)=(.+)$/) {
                            my ($vn, $val) = ($1, $2);
                            return { error => "Unknown: $vn=$val" } unless exists $var_map{$vn}{$val};
                            push @lits, $var_map{$vn}{$val};
                        }
                    }
                    if (@lits >= $k) {
                        my @atleast = _combinations(\@lits, $k - 1);
                        for my $combo (@atleast) {
                            push @clauses, [map { -$_ } @$combo];
                        }
                    }
                    if (@lits > $k) {
                        my @atmost = _combinations(\@lits, $k + 1);
                        for my $combo (@atmost) {
                            push @clauses, [map { -$_ } @$combo];
                        }
                    }
                }

                elsif ($type eq 'alldiff') {
                    my @anames = @{$c->{vars} // []};
                    my @all_svars;
                    for my $vn (@anames) {
                        return { error => "Unknown variable '$vn'" } unless exists $var_map{$vn};
                        push @all_svars, { name => $vn, svars => $var_map{$vn} };
                    }
                    for my $i (0..$#all_svars) {
                        for my $j ($i+1..$#all_svars) {
                            my $vi = $all_svars[$i];
                            my $vj = $all_svars[$j];
                            for my $val (keys %{$vi->{svars}}) {
                                next unless exists $vj->{svars}{$val};
                                push @clauses, [-$vi->{svars}{$val}, -$vj->{svars}{$val}];
                            }
                        }
                    }
                }

                elsif ($type eq 'implies') {
                    my ($ant, $cons) = @{$c}{qw(antecedent consequent)};
                    my @ant_lits = _parse_literal_list($ant, \%var_map);
                    my @cons_lits = _parse_literal_list($cons, \%var_map);
                    my @neg_ant = map { -$_ } @ant_lits;
                    push @clauses, [@neg_ant, @cons_lits];
                }

                elsif ($type eq 'xor') {
                    my @lits;
                    for my $lit (@{$c->{literals} // []}) {
                        if ($lit =~ /^(\w+)=(.+)$/) {
                            return { error => "Unknown: $1=$2" } unless exists $var_map{$1}{$2};
                            push @lits, $var_map{$1}{$2};
                        }
                    }
                    my $n = scalar @lits;
                    for my $mask (0..2**$n - 1) {
                        my $bits = 0;
                        for my $b (0..$n-1) { $bits++ if $mask & (1 << $b); }
                        next if $bits % 2 == 0;
                        push @clauses, [map { ($mask & (1 << $_)) ? $lits[$_] : -$lits[$_] } 0..$n-1];
                    }
                }

                elsif ($type eq 'iff') {
                    my ($a, $b) = @{$c}{qw(a b)};
                    my @a_lits = _parse_literal_list($a, \%var_map);
                    my @b_lits = _parse_literal_list($b, \%var_map);
                    push @clauses, [map { -$_ } @a_lits, @b_lits];
                    push @clauses, [map { -$_ } @b_lits, @a_lits];
                }
            }

            my $num_vars = $next_var - 1;
            my $num_clauses = scalar @clauses;

            my $dimacs = "p cnf $num_vars $num_clauses\n";
            for my $clause (@clauses) {
                $dimacs .= join(' ', @$clause) . " 0\n";
            }

            return {
                ok          => 1,
                dimacs      => $dimacs,
                var_map     => \%var_map,
                num_vars    => $num_vars,
                num_clauses => $num_clauses,
            };
        },
    );
}

sub _parse_literal_list {
    my ($spec, $vmap) = @_;
    return () unless $spec;
    if (ref $spec eq 'ARRAY') {
        my @result;
        for my $lit (@$spec) {
            if ($lit =~ /^(\w+)=(.+)$/) {
                push @result, $vmap->{$1}{$2} if exists $vmap->{$1}{$2};
            }
        }
        return @result;
    }
    if ($spec =~ /^(\w+)=(.+)$/) {
        return ($vmap->{$1}{$2}) if exists $vmap->{$1}{$2};
    }
    return ();
}

sub _combinations {
    my ($arr, $k) = @_;
    return ([]) if $k == 0;
    return () unless @$arr >= $k;
    my @result;
    for my $i (0..$#$arr - $k + 1) {
        my @rest = @{$arr}[$i+1..$#$arr];
        my @subs = _combinations(\@rest, $k - 1);
        for my $sub (@subs) {
            my @flat = @$sub;
            push @result, [$arr->[$i], @flat];
            return @result if @result > 100_000;
        }
    }
    return @result;
}

1;
