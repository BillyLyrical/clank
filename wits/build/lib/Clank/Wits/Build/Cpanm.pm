# CLANK-WIT: name=Cpanm
# CLANK-WIT: version=1.0.0
# CLANK-WIT: about=Install Perl modules via cpanm
# CLANK-WIT: usage=Input: { module: "Moo", install_base: "/usr/local" } Output: { ok: true, output: "...", exit_code: 0 }
# CLANK-WIT: hint=cpanm install perl modules, cpan minus, dependency management
# CLANK-WIT: author=Clank
# CLANK-WIT: license=Artistic-2.0
package Clank::Wits::Build::Cpanm;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;
    $api->register_tool(
        name        => 'build_cpanm',
        description => 'Install Perl modules via cpanm',
        parameters  => {
            type       => 'object',
            properties => {
                module       => { type => 'string', description => 'Module name or dist' },
                install_base => { type => 'string', description => 'Install base directory' },
                notest       => { type => 'boolean', description => 'Skip tests' },
                verbose      => { type => 'boolean', description => 'Verbose output' },
            },
            required => ['module'],
        },
        execute => sub {
            my ($args) = @_;
            my $module = $args->{module} // '';
            my $base   = $args->{install_base} // '';
            my $notest = $args->{notest}  ? '--notest' : '';
            my $verb   = $args->{verbose} ? '--verbose' : '';

            return { error => "No module specified" } unless $module;

            my $cmd = "cpanm $notest $verb";
            $cmd .= " -l $base" if $base;
            $cmd .= " $module 2>&1";

            my $output = `$cmd`;
            my $exit_code = $? >> 8;

            return {
                ok        => $exit_code == 0 ? 1 : 0,
                output    => $output,
                exit_code => $exit_code,
                module    => $module,
            };
        },
    );
}

1;
