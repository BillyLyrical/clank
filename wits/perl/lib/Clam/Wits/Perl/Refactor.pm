# CLAM-WIT: name=Refactor
# CLAM-WIT: version=1.0.0
# CLAM-WIT: about=Suggest refactoring improvements for Perl code
# CLAM-WIT: usage=Input: { code: "sub foo { if ($x) { return 1; } else { return 0; } }" } Output: { suggestions: [{ type: "simplify", before: "...", after: "..." }] }
# CLAM-WIT: hint=perl_refactor, refactoring, code improvement, modernize
# CLAM-WIT: author=CLAM
# CLAM-WIT: license=Artistic-2.0
package Clam::Wits::Perl::Refactor;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'perl_refactor',
        description => 'Suggest refactoring improvements for Perl code',
        parameters  => {
            type       => 'object',
            properties => {
                code => { type => 'string', description => 'Perl code to refactor' },
            },
            required => ['code'],
        },
        execute => sub {
            my ($args) = @_;
            my $code = $args->{code} // '';

            return { suggestions => [] } unless $code;

            my @suggestions;

            if ($code =~ /if\s*\((.+?)\)\s*\{\s*return\s+(\d+)\s*;\s*\}\s*else\s*\{\s*return\s+(\d+)\s*;\s*\}/) {
                my ($cond, $true, $false) = ($1, $2, $3);
                push @suggestions, {
                    type   => 'simplify',
                    before => "if ($cond) { return $true; } else { return $false; }",
                    after  => "return $cond ? $true : $false;",
                };
            }

            if ($code =~ /\bmap\s*\{\s*\$_\s*\}\s*(\@[\w]+)/) {
                push @suggestions, {
                    type   => 'simplify',
                    before => "map { \$_ } $1",
                    after  => "[\@$1[0 .. \$#$1]]",
                };
            }

            if ($code =~ /my\s+\@result;\s*for\s+my\s+\\\$(\w+)\s+\((\@[\w]+)\)\s*\{\s*push\s+\@result,\s*(.+?)\s*;\s*\}/s) {
                my ($var, $array, $expr) = ($1, $2, $3);
                push @suggestions, {
                    type   => 'modernize',
                    before => "my \@result;\nfor my \$$var (\$array) {\n    push \@result, $expr;\n}",
                    after  => "my \@result = map { my \$$var = \$_; $expr } \$$array;",
                };
            }

            if ($code =~ /\bmy\s+\\\$(?:max|min)\s*=.*for.*\@/) {
                push @suggestions, {
                    type   => 'modernize',
                    before => 'Manual max/min calculation',
                    after  => 'use List::Util qw(max min); my $max = max @array;',
                };
            }

            return { suggestions => \@suggestions };
        },
    );
}

1;
