# CLAM-WIT: name=WarnCheck
# CLAM-WIT: version=1.0.0
# CLAM-WIT: about=Find potential Perl warnings, suggest fixes
# CLAM-WIT: usage=Input: { code: "print $x; my $y = $undefined;" } Output: { warnings: [{ type: "uninitialized", line: 1, msg: "..." }] }
# CLAM-WIT: hint=perl_warn_check, warnings, uninitialized, static analysis
# CLAM-WIT: author=CLAM
# CLAM-WIT: license=Artistic-2.0
package AI::Clam::Wits::Perl::WarnCheck;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'perl_warn_check',
        description => 'Find potential Perl warnings, suggest fixes',
        parameters  => {
            type       => 'object',
            properties => {
                code => { type => 'string', description => 'Perl code to check' },
            },
            required => ['code'],
        },
        execute => sub {
            my ($args) = @_;
            my $code = $args->{code} // '';

            return { warnings => [] } unless $code;

            my @warnings;
            my @lines = split /\n/, $code;

            for my $i (0 .. $#lines) {
                my $line = $lines[$i];
                my $num = $i + 1;

                if ($line =~ /\$(\w+)\s*(?:[!=<>]=|[\+\-\*\/])/ && $line !~ /\bdefined\b/) {
                    push @warnings, {
                        type   => 'uninitialized',
                        line   => $num,
                        msg    => "Variable \$$1 may be uninitialized",
                        fix    => "Add defined($1) check or initialize",
                    };
                }

                if ($line =~ /\$[\w]+\s*eq\s*['"]/) {
                    push @warnings, {
                        type   => 'style',
                        line   => $num,
                        msg    => "String comparison — consider using 'eq' explicitly",
                        fix    => "Ensure consistent string comparison",
                    };
                }

                if ($line =~ /\@(\w+)\s*(?:[=!<>]=|\+)/) {
                    push @warnings, {
                        type   => 'scalar_context',
                        line   => $num,
                        msg    => "Array \@$1 in scalar context — returns array size",
                        fix    => "Use scalar(\@$1) for clarity",
                    };
                }

                if ($line =~ m{[^\\]/} && $line !~ /\$\s*\/$/ && $line !~ /\\[nzb]/) {
                    push @warnings, {
                        type   => 'regex',
                        line   => $num,
                        msg    => "Regex may need anchors (^ or \$)",
                        fix    => "Add ^ or \$ if matching start/end of string",
                    };
                }
            }

            return { warnings => \@warnings };
        },
    );
}

1;
