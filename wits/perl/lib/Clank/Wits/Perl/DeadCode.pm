# CLANK-WIT: name=DeadCode
# CLANK-WIT: version=1.0.0
# CLANK-WIT: about=Find unused subroutines and variables in Perl code
# CLANK-WIT: usage=Input: { code: "sub used { } sub unused { } my $x = 1;" } Output: { unused_subs: ["unused"], unused_vars: ["$x"] }
# CLANK-WIT: hint=perl_dead_code, unused code, dead code, unused subs, unused variables
# CLANK-WIT: author=Clank
# CLANK-WIT: license=Artistic-2.0
package Clank::Wits::Perl::DeadCode;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'perl_dead_code',
        description => 'Find unused subroutines and variables in Perl code',
        parameters  => {
            type       => 'object',
            properties => {
                code => { type => 'string', description => 'Perl code to analyze' },
            },
            required => ['code'],
        },
        execute => sub {
            my ($args) = @_;
            my $code = $args->{code} // '';

            return { unused_subs => [], unused_vars => [] } unless $code;

            my @subs;
            while ($code =~ /^sub\s+(\w+)/gm) {
                push @subs, $1;
            }

            my @vars;
            while ($code =~ /\bmy\s+(\$[\w]+)/g) {
                push @vars, $1;
            }

            my @unused_subs;
            for my $sub (@subs) {
                my $escaped = quotemeta($sub);
                my @refs = ($code =~ /\b$escaped\b/g);
                push @unused_subs, $sub if @refs <= 1;
            }

            my @unused_vars;
            for my $var (@vars) {
                my $escaped = quotemeta($var);
                my @refs = ($code =~ /\b$escaped\b/g);
                push @unused_vars, $var if @refs <= 1;
            }

            return {
                unused_subs => \@unused_subs,
                unused_vars => \@unused_vars,
            };
        },
    );
}

1;
