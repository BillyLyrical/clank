# CLANK-WIT: name=CodingStandards
# CLANK-WIT: version=1.0.0
# CLANK-WIT: about=Review code against Perl coding standards — readability, KISS, DRY, YAGNI, code smells
# CLANK-WIT: usage=Input: { file: "path/to/file.pm" } Output: { score: number, issues: [...], summary: string }
# CLANK-WIT: hint=coding standards, code review, style, naming, readability, KISS, DRY, YAGNI, code smells, Perl style
# CLANK-WIT: author=Clank
# CLANK-WIT: license=Artistic-2.0
package Clank::Wits::Critic::CodingStandards;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'coding_standards',
        description => 'Review code against Perl coding standards',
        parameters  => {
            type       => 'object',
            properties => {
                file => { type => 'string', description => 'Path to file to review' },
            },
            required => ['file'],
        },
        execute => sub {
            my ($args) = @_;
            my $file = $args->{file} // '';
            return { error => "No file provided" } unless $file;
            return { error => "File not found: $file" } unless -f $file;

            open my $fh, '<', $file or return { error => "Cannot open $file: $!" };
            my @lines = <$fh>;
            close $fh;

            my $score     = 100;
            my @issues;
            my @subs;

            my $text = join '', @lines;

            if ($text !~ /\buse strict\b/) {
                push @issues, { severity => 'high', category => 'pragmas', line => 0, message => 'Missing use strict', suggestion => 'Add "use strict;" at top of file' };
                $score -= 15;
            }
            if ($text !~ /\buse warnings\b/) {
                push @issues, { severity => 'medium', category => 'pragmas', line => 0, message => 'Missing use warnings', suggestion => 'Add "use warnings;" at top of file' };
                $score -= 5;
            }

            my $in_sub = 0;
            my $sub_start;
            my $sub_name;
            my @nest_stack;
            my $nest_level = 0;

            for my $i (0 .. $#lines) {
                my $ln = $i + 1;
                my $line = $lines[$i];

                if ($line =~ /\bsub\s+([a-zA-Z_]\w*)/) {
                    $sub_name = $1;
                    $in_sub = 1;
                    $sub_start = $ln;
                }
                if ($in_sub && $sub_start && ($ln - $sub_start) > 50) {
                    push @issues, { severity => 'medium', category => 'length', line => $sub_start, message => "Subroutine $sub_name exceeds 50 lines", suggestion => 'Break into smaller functions' };
                    $in_sub = 0;
                }
                if ($in_sub && $sub_name && $line =~ /^1;\s*$/ || ($in_sub && $line =~ /^__END__/)) {
                    $in_sub = 0;
                }

                my $open  = () = $line =~ /\b(?:if|elsif|while|for|foreach|unless)\b/g;
                my $close = () = $line =~ /\}/g;
                $nest_level += $open - $close;
                if ($nest_level > 4) {
                    push @issues, { severity => 'medium', category => 'nesting', line => $ln, message => "Deep nesting (level $nest_level)", suggestion => 'Extract nested logic into helper functions' };
                }

                if ($line =~ /^\s*#/ && $line =~ /(?:^|\s)(?:my |if |while |for |return |\$|print)/) {
                    push @issues, { severity => 'low', category => 'comments', line => $ln, message => 'Commented-out code', suggestion => 'Remove commented-out code; use version control instead' };
                }

                if ($line =~ /\bmy\s+(\$[a-zA-Z])\b/ && $1 ne '$i' && $1 ne '$j' && $1 ne '$_' && $1 ne '$x') {
                    (my $var = $1) =~ s/^\$//;
                    if (length($var) == 1 && $var !~ /^[ij_]/) {
                        push @issues, { severity => 'low', category => 'naming', line => $ln, message => "Single-letter variable $1", suggestion => 'Use a descriptive variable name' };
                    }
                }

                if ($line =~ /(?:^|[^0-9a-zA-Z_])((?!0|1|2)\d{2,})(?:[^0-9a-zA-Z_]|$)/ && $line !~ /^\s*#/ && $line !~ /=>\s*\d/ && $line !~ /use\s+\w+/ && $line !~ /version/) {
                    my $num = $1;
                    push @issues, { severity => 'low', category => 'magic_numbers', line => $ln, message => "Magic number $num", suggestion => 'Extract to a named constant' };
                }
            }

            my $sub_count = () = $text =~ /\bsub\s+[a-zA-Z_]\w*/g;
            my $func_count = ($text =~ /\bsub\b/g) // 0;

            my $summary = scalar(@issues) == 0
                ? "No coding standards issues found."
                : scalar(@issues) . " issue(s) found. Score: $score/100.";

            $score = 0 if $score < 0;

            return {
                score   => $score,
                issues  => \@issues,
                summary => $summary,
            };
        },
    );
}

1;
