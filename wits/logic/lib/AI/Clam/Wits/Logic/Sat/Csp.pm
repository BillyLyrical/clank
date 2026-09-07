# CLAM-WIT: name=Csp
# CLAM-WIT: version=1.0.0
# CLAM-WIT: about=Solve a Constraint Satisfaction Problem end-to-end
# CLAM-WIT: usage=Input: { variables: { X1: [1,2,3], X2: [1,2,3] }, constraints: [...] } Output: { ok: true, sat: true, solution: {X1: 1, X2: 3} }
# CLAM-WIT: hint=sat_csp, csp, constraint_satisfaction, nqueens, sudoku, graph_coloring
# CLAM-WIT: author=CLAM
# CLAM-WIT: license=Artistic-2.0
package AI::Clam::Wits::Logic::Sat::Csp;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'sat.csp',
        description => 'Solve a Constraint Satisfaction Problem end-to-end',
        parameters  => {
            type       => 'object',
            properties => {
                variables   => { type => 'object', description => 'Variable domains: { name: [values] }' },
                constraints => { type => 'array',  description => 'Constraint specifications' },
                bool_vars   => { type => 'array',  description => 'Boolean variable names' },
                solver      => { type => 'string', description => 'SAT solver binary (default: picosat)' },
                preset      => { type => 'string', description => 'Preset problem: nqueens, graph_color, sudoku, schedule' },
                workspace   => { type => 'string', description => 'Workspace dir for output files' },
                n           => { type => 'integer', description => 'Board size for nqueens preset' },
                colors      => { type => 'integer', description => 'Number of colors for graph_color preset' },
                edges       => { type => 'array',  description => 'Graph edges for graph_color preset' },
                nodes       => { type => 'array',  description => 'Graph nodes for graph_color preset' },
                grid        => { type => 'array',  description => '81 values for sudoku preset (0 = empty)' },
                tasks       => { type => 'array',  description => 'Task names for schedule preset' },
                slots       => { type => 'array',  description => 'Time slots for schedule preset' },
                conflicts   => { type => 'array',  description => 'Conflict pairs for schedule preset' },
            },
            required => [],
        },
        execute => sub {
            my ($args) = @_;
            my $input = $args;
            my $vars_def    = ref $input eq 'HASH' ? ($input->{variables}    // {}) : {};
            my $constraints = ref $input eq 'HASH' ? ($input->{constraints}  // []) : [];
            my $bool_vars   = ref $input eq 'HASH' ? ($input->{bool_vars}   // []) : [];
            my $solver      = ref $input eq 'HASH' ? ($input->{solver}      // '')  : '';
            my $presets     = ref $input eq 'HASH' ? ($input->{preset}      // '')  : '';
            my $workspace   = ref $input eq 'HASH' ? ($input->{workspace}   // '')  : '';

            if ($presets eq 'nqueens') {
                my $n = ref $input eq 'HASH' ? ($input->{n} // 8) : 8;
                my %Q;
                for my $r (1..$n) {
                    $Q{"Q$r"} = [1..$n];
                }
                my @constr;
                for my $c (1..$n) {
                    my @col_lits;
                    for my $r (1..$n) {
                        push @col_lits, "Q$r=$c";
                    }
                    push @constr, { type => 'atmost', k => 1, literals => \@col_lits };
                }
                for my $r1 (1..$n) {
                    for my $r2 ($r1+1..$n) {
                        my $d = $r2 - $r1;
                        for my $c (1..$n) {
                            my $c2r = $c + $d;
                            if ($c2r >= 1 && $c2r <= $n) {
                                push @constr, { type => 'atmost', k => 1, literals => ["Q$r1=$c", "Q$r2=$c2r"] };
                            }
                            my $c2l = $c - $d;
                            if ($c2l >= 1 && $c2l <= $n) {
                                push @constr, { type => 'atmost', k => 1, literals => ["Q$r1=$c", "Q$r2=$c2l"] };
                            }
                        }
                    }
                }
                $vars_def = \%Q;
                $constraints = \@constr;
            }

            elsif ($presets eq 'graph_color') {
                my $colors = ref $input eq 'HASH' ? ($input->{colors} // 3) : 3;
                my $edges  = ref $input eq 'HASH' ? ($input->{edges}  // []) : [];
                my $nodes  = ref $input eq 'HASH' ? ($input->{nodes}  // []) : [];

                my %G;
                for my $n (@$nodes) {
                    $G{$n} = [1..$colors];
                }
                my @constr;
                for my $e (@$edges) {
                    my ($a, $b);
                    if (ref $e eq 'ARRAY') {
                        ($a, $b) = @$e;
                    } elsif ($e =~ /^(\w+)-(\w+)$/) {
                        ($a, $b) = ($1, $2);
                    }
                    next unless $a && $b;
                    push @constr, { type => 'alldiff', vars => [$a, $b] };
                }
                $vars_def = \%G;
                $constraints = \@constr;
            }

            elsif ($presets eq 'sudoku') {
                my $grid = ref $input eq 'HASH' ? ($input->{grid} // []) : [];
                return { error => "sudoku preset requires grid (81 values)" } unless @$grid == 81;

                my %S;
                for my $i (0..80) {
                    my $val = $grid->[$i];
                    if ($val && $val > 0) {
                        $S{"R$i"} = [$val];
                    } else {
                        $S{"R$i"} = [1..9];
                    }
                }

                my @constr;
                for my $row (0..8) {
                    my @cells = map { "R" . ($row * 9 + $_) } 0..8;
                    push @constr, { type => 'alldiff', vars => \@cells };
                }
                for my $col (0..8) {
                    my @cells = map { "R" . ($_ * 9 + $col) } 0..8;
                    push @constr, { type => 'alldiff', vars => \@cells };
                }
                for my $br (0..2) {
                    for my $bc (0..2) {
                        my @cells;
                        for my $r (0..2) {
                            for my $c (0..2) {
                                push @cells, "R" . (($br*3+$r)*9 + $bc*3+$c);
                            }
                        }
                        push @constr, { type => 'alldiff', vars => \@cells };
                    }
                }

                $vars_def = \%S;
                $constraints = \@constr;
            }

            elsif ($presets eq 'schedule') {
                my $tasks    = ref $input eq 'HASH' ? ($input->{tasks}    // []) : [];
                my $slots    = ref $input eq 'HASH' ? ($input->{slots}    // []) : [];
                my $conflicts= ref $input eq 'HASH' ? ($input->{conflicts}// []) : [];

                my %T;
                for my $task (@$tasks) {
                    $T{$task} = [0..$#$slots];
                }
                my @constr;
                for my $s (0..$#$slots) {
                    my @task_lits = map { "$_=$s" } @$tasks;
                    push @constr, { type => 'atmost', k => 1, literals => \@task_lits };
                }
                for my $task (@$tasks) {
                    my @slot_lits = map { "$task=$_" } 0..$#$slots;
                    push @constr, { type => 'exactly', k => 1, literals => \@slot_lits };
                }
                for my $conf (@$conflicts) {
                    my ($a, $b) = @$conf;
                    for my $sa (0..$#$slots) {
                        for my $sb (0..$#$slots) {
                            next if abs($sa - $sb) > 1;
                            push @constr, { type => 'atmost', k => 1, literals => ["$a=$sa", "$b=$sb"] };
                        }
                    }
                }

                $vars_def = \%T;
                $constraints = \@constr;
            }

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
                            next unless exists $var_map{$1}{$2};
                            push @lits, $neg ? -$var_map{$1}{$2} : $var_map{$1}{$2};
                        }
                    }
                    push @clauses, [@lits] if @lits;
                }
                elsif ($type eq 'alldiff') {
                    my @an = @{$c->{vars} // []};
                    my @svs = map { exists $var_map{$_} ? { name => $_, sv => $var_map{$_} } : () } @an;
                    for my $i (0..$#svs) {
                        for my $j ($i+1..$#svs) {
                            for my $val (keys %{$svs[$i]{sv}}) {
                                next unless exists $svs[$j]{sv}{$val};
                                push @clauses, [-$svs[$i]{sv}{$val}, -$svs[$j]{sv}{$val}];
                            }
                        }
                    }
                }
                elsif ($type eq 'atmost') {
                    my $k = $c->{k} // 1;
                    my @lits = map { /^(\w+)=(.+)$/ && exists $var_map{$1}{$2} ? $var_map{$1}{$2} : () } @{$c->{literals} // []};
                    if (@lits > $k) {
                        my @combos = _sat_combos(\@lits, $k + 1);
                        push @clauses, [map { -$_ } @$_] for @combos;
                    }
                }
                elsif ($type eq 'atleast') {
                    my $k = $c->{k} // 1;
                    my @lits = map { /^(\w+)=(.+)$/ && exists $var_map{$1}{$2} ? $var_map{$1}{$2} : () } @{$c->{literals} // []};
                    if (@lits >= $k) {
                        my @combos = _sat_combos(\@lits, $k - 1);
                        push @clauses, [map { -$_ } @$_] for @combos;
                    }
                }
                elsif ($type eq 'exactly') {
                    my $k = $c->{k} // 1;
                    my @lits = map { /^(\w+)=(.+)$/ && exists $var_map{$1}{$2} ? $var_map{$1}{$2} : () } @{$c->{literals} // []};
                    if (@lits >= $k) {
                        my @alc = _sat_combos(\@lits, $k - 1);
                        push @clauses, [map { -$_ } @$_] for @alc;
                    }
                    if (@lits > $k) {
                        my @amc = _sat_combos(\@lits, $k + 1);
                        push @clauses, [map { -$_ } @$_] for @amc;
                    }
                }
                elsif ($type eq 'implies') {
                    my ($ant, $cons) = @{$c}{qw(antecedent consequent)};
                    my @al = _sat_parse($ant, \%var_map);
                    my @cl = _sat_parse($cons, \%var_map);
                    if (@al && @cl) {
                        my @neg_al = map { -$_ } @al;
                        push @clauses, [@neg_al, @cl];
                    }
                }
                elsif ($type eq 'xor') {
                    my @lits = map { /\w+=(.+)/ && exists $var_map{$`} ? $var_map{$`}{$1} : () } @{$c->{literals} // []};
                    my $n = @lits;
                    for my $mask (0..2**$n - 1) {
                        my $bits = 0;
                        for my $b (0..$n-1) { $bits++ if $mask & (1 << $b); }
                        next if $bits % 2 == 0;
                        push @clauses, [map { ($mask & (1 << $_)) ? $lits[$_] : -$lits[$_] } 0..$n-1];
                    }
                }
                elsif ($type eq 'iff') {
                    my ($a, $b) = @{$c}{qw(a b)};
                    my @al = _sat_parse($a, \%var_map);
                    my @bl = _sat_parse($b, \%var_map);
                    if (@al && @bl) {
                        push @clauses, [map { -$_ } @al, @bl];
                        push @clauses, [map { -$_ } @bl, @al];
                    }
                }
            }

            my $num_vars = $next_var - 1;
            my $num_clauses = scalar @clauses;
            my $dimacs = "p cnf $num_vars $num_clauses\n";
            $dimacs .= join(' ', @$_) . " 0\n" for @clauses;

            require File::Path;
            require FindBin;
            my $workdir = do {
                my $wd = "$FindBin::Bin/../../_work";
                File::Path::make_path($wd) unless -d $wd;
                $wd;
            };
            my $cnf_file = "$workdir/csp_$$.cnf";

            open my $fh, '>', $cnf_file or return { error => "Cannot write CNF: $!" };
            print $fh $dimacs;
            close $fh;

            my $solver_bin = $solver || 'picosat';
            my $has_pico = system("which picosat >/dev/null 2>&1") == 0;
            unless ($has_pico) {
                return { error => "picosat required but not found in PATH" };
            }

            my $out_file = "$cnf_file.out";
            my $cmd = "picosat -o $out_file $cnf_file 2>&1";

            alarm(30);
            my $sout = `$cmd`;
            my $sexit = $? >> 8;
            alarm(0);

            my $sat = 0;
            my $unsat = 0;
            my @model;

            if (-f $out_file) {
                open my $ofh, '<', $out_file;
                while (<$ofh>) {
                    chomp;
                    $sat = 1 if /^s\s+SATISFIABLE/;
                    $unsat = 1 if /^s\s+UNSATISFIABLE/;
                    if (/^v\s+(.*)/) {
                        push @model, grep { $_ != 0 } split /\s+/, $1;
                    }
                }
                close $ofh;
            }
            $sat = 1 if $sexit == 10;
            $unsat = 1 if $sexit == 20;

            my %solution;
            if ($sat) {
                my %assign;
                $assign{abs($_)} = $_ > 0 ? 1 : -1 for @model;

                for my $vn (keys %var_map) {
                    for my $val (keys %{$var_map{$vn}}) {
                        my $sv = $var_map{$vn}{$val};
                        if (exists $assign{$sv} && $assign{$sv} > 0) {
                            $solution{$vn} = $val;
                        }
                    }
                }
            }

            my $display = '';
            if ($sat) {
                $display = "SATISFIABLE\n";
                for my $k (sort keys %solution) {
                    $display .= "  $k = $solution{$k}\n";
                }
            } else {
                $display = "UNSATISFIABLE\n";
            }

            unlink $cnf_file;
            unlink $out_file;

            return {
                ok          => 1,
                sat         => $sat ? 1 : 0,
                unsat       => $unsat ? 1 : 0,
                solution    => %solution ? \%solution : undef,
                display     => $display,
                solver      => $solver_bin,
                variables   => scalar keys %var_map,
                clauses     => $num_clauses,
                preset      => $presets || undef,
                workspace   => $workspace || undef,
            };
        },
    );
}

sub _sat_parse {
    my ($spec, $vmap) = @_;
    return () unless $spec;
    if (ref $spec eq 'ARRAY') {
        my @r;
        for my $l (@$spec) {
            if ($l =~ /^(\w+)=(.+)$/ && exists $vmap->{$1}{$2}) {
                push @r, $vmap->{$1}{$2};
            }
        }
        return @r;
    }
    if ($spec =~ /^(\w+)=(.+)$/ && exists $vmap->{$1}{$2}) {
        return ($vmap->{$1}{$2});
    }
    return ();
}

sub _sat_combos {
    my ($arr, $k) = @_;
    return ([]) if $k == 0;
    return () unless @$arr >= $k;
    my @r;
    for my $i (0..$#$arr - $k + 1) {
        my @rest = @{$arr}[$i+1..$#$arr];
        for my $sub (_sat_combos(\@rest, $k - 1)) {
            my @flat = @$sub;
            push @r, [$arr->[$i], @flat];
            return @r if @r > 100_000;
        }
    }
    return @r;
}

1;
