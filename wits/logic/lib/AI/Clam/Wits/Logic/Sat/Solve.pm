# CLAM-WIT: name=Solve
# CLAM-WIT: version=1.0.0
# CLAM-WIT: about=Run picosat on DIMACS CNF and parse result
# CLAM-WIT: usage=Input: { dimacs: "p cnf 3 2\n1 2 0\n-1 3 0\n" } Output: { ok: true, sat: true, assignments: {1: 1, 2: 1, 3: -1} }
# CLAM-WIT: hint=sat_solve, sat, solver, picosat, dimacs, cnf, satisfiability
# CLAM-WIT: author=CLAM
# CLAM-WIT: license=Artistic-2.0
# NEEDS REVIEW: previous test used excessive RAM — do not re-enable until memory usage is profiled and bounded.
package AI::Clam::Wits::Logic::Sat::Solve;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'sat.solve',
        description => 'Run picosat on DIMACS CNF and parse result',
        parameters  => {
            type       => 'object',
            properties => {
                dimacs  => { type => 'string', description => 'DIMACS CNF format string' },
                solver  => { type => 'string', description => 'SAT solver binary (default: picosat)' },
                var_map => { type => 'object', description => 'Variable name to SAT variable mapping' },
                file    => { type => 'string', description => 'Path to existing CNF file' },
            },
            required => [],
        },
        execute => sub {
            my ($args) = @_;
            my $input = $args;
            my $dimacs = ref $input eq 'HASH' ? ($input->{dimacs}  // '') : "$input";
            my $solver = ref $input eq 'HASH' ? ($input->{solver} // 'picosat') : 'picosat';
            my $var_map= ref $input eq 'HASH' ? ($input->{var_map}// {}) : {};
            my $file   = ref $input eq 'HASH' ? ($input->{file}   // '')  : '';

            return { error => "dimacs or file required" } unless $dimacs || $file;

            unless ($solver eq 'picosat') {
                return { error => "Only picosat is supported (minisat removed — excessive RAM usage)" };
            }

            require File::Path;
            require FindBin;
            my $workdir = do {
                my $wd = "$FindBin::Bin/../../_work";
                File::Path::make_path($wd) unless -d $wd;
                $wd;
            };
            my $cnf_file = $file || "$workdir/sat_$$.cnf";
            if ($dimacs && !$file) {
                open my $fh, '>', $cnf_file or return { error => "Cannot write CNF: $!" };
                print $fh $dimacs;
                close $fh;
            }

            my $out_file = "$cnf_file.out";

            my $cmd = "picosat -o $out_file $cnf_file 2>&1";

            alarm(30);
            my $solver_out = `$cmd`;
            my $solver_exit = $? >> 8;
            alarm(0);

            my $sat = 0;
            my @model;
            my $unsat = 0;

            if (-f $out_file) {
                open my $fh, '<', $out_file;
                while (<$fh>) {
                    chomp;
                    if ($_ =~ /^s\s+(SATISFIABLE|UNSATISFIABLE|SAT|UNSAT)/i) {
                        $sat = ($1 =~ /SATISFIABLE/i && $1 !~ /UNSATISFIABLE/i);
                        $unsat = ($1 =~ /UNSATISFIABLE/i);
                    }
                    if ($_ =~ /^v\s+(.*)/) {
                        my @vals = split /\s+/, $1;
                        @model = grep { $_ != 0 } @vals;
                    }
                }
                close $fh;
            } else {
                if ($solver_out =~ /SATISFIABLE/) { $sat = 1; }
                if ($solver_out =~ /UNSATISFIABLE/) { $unsat = 1; }
                if ($solver_out =~ /^v\s+(.*)/m) {
                    @model = grep { $_ != 0 } split /\s+/, $1;
                }
            }

            $sat = 1 if $solver_exit == 10;
            $unsat = 1 if $solver_exit == 20;

            my %assignments;
            for my $val (@model) {
                $assignments{abs($val)} = $val > 0 ? 1 : -1;
            }

            my %readable;
            if ($var_map && %$var_map) {
                for my $vname (keys %$var_map) {
                    for my $val (keys %{$var_map->{$vname}}) {
                        my $sv = $var_map->{$vname}{$val};
                        if (exists $assignments{$sv}) {
                            if ($assignments{$sv} > 0) {
                                $readable{$vname} = $val;
                            }
                        }
                    }
                }
            }

            unlink $cnf_file unless $file;
            unlink $out_file;

            return {
                ok          => 1,
                sat         => $sat ? 1 : 0,
                unsat       => $unsat ? 1 : 0,
                solver      => $solver,
                assignments => \%assignments,
                readable    => %readable ? \%readable : undef,
                model_size  => scalar @model,
                raw         => $solver_out,
            };
        },
    );
}

1;
