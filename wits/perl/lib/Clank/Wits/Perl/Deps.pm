# CLANK-WIT: name=Deps
# CLANK-WIT: version=1.0.0
# CLANK-WIT: about=Check which Perl modules are used and which are missing
# CLANK-WIT: usage=Input: { code: "use DBI; use Moose; use Fake::Module;" } Output: { used: [...], missing: [...], installed: [...] }
# CLANK-WIT: hint=perl_deps, dependencies, modules, missing, installed
# CLANK-WIT: author=Clank
# CLANK-WIT: license=Artistic-2.0
package Clank::Wits::Perl::Deps;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'perl_deps',
        description => 'Check which Perl modules are used and which are missing',
        parameters  => {
            type       => 'object',
            properties => {
                code => { type => 'string', description => 'Perl code to scan' },
            },
            required => ['code'],
        },
        execute => sub {
            my ($args) = @_;
            my $code = $args->{code} // '';

            return { used => [], missing => [], installed => [] } unless $code;

            my @modules;
            while ($code =~ /\b(?:use|require)\s+([A-Z][A-Za-z0-9_:]+)/g) {
                push @modules, $1 unless grep { $_ eq $1 } @modules;
            }

            my @installed;
            my @missing;

            for my $mod (@modules) {
                if (eval { require $mod; 1 }) {
                    push @installed, $mod;
                } else {
                    push @missing, $mod;
                }
            }

            return {
                used      => \@modules,
                installed => \@installed,
                missing   => \@missing,
            };
        },
    );
}

1;
