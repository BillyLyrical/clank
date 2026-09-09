# CLANK-WIT: name=PerlBuild
# CLANK-WIT: version=1.0.0
# CLANK-WIT: about=Build Perl modules via Makefile.PL or Build.PL
# CLANK-WIT: usage=Input: { action: "build", dir: "/path/to/module" } Output: { ok: true, output: "...", exit_code: 0 }
# CLANK-WIT: hint=perl build, makefile pl, build pl, module install, perl development
# CLANK-WIT: author=Clank
# CLANK-WIT: license=Artistic-2.0
package Clank::Wits::Build::PerlBuild;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;
    $api->register_tool(
        name        => 'build_perl_build',
        description => 'Build Perl modules via Makefile.PL or Build.PL',
        parameters  => {
            type       => 'object',
            properties => {
                action => { type => 'string', enum => ['configure', 'build', 'test', 'install'], description => 'Build action' },
                dir    => { type => 'string', description => 'Module directory' },
                args   => { type => 'string', description => 'Extra arguments' },
            },
            required => ['action'],
        },
        execute => sub {
            my ($args) = @_;
            my $action = $args->{action} // 'build';
            my $dir    = $args->{dir}    // '.';
            my $extra  = $args->{args}   // '';

            return { error => "Directory not found: $dir" } unless -d $dir;

            my $cmd;
            if (-f "$dir/Build.PL") {
                $cmd = {
                    configure => "cd $dir && perl Build.PL $extra",
                    build     => "cd $dir && perl Build",
                    test      => "cd $dir && perl Build test",
                    install   => "cd $dir && perl Build install",
                }->{$action};
            }
            elsif (-f "$dir/Makefile.PL") {
                $cmd = {
                    configure => "cd $dir && perl Makefile.PL $extra",
                    build     => "cd $dir && make",
                    test      => "cd $dir && make test",
                    install   => "cd $dir && make install",
                }->{$action};
            }
            else {
                return { error => "No Makefile.PL or Build.PL found in $dir" };
            }

            return { error => "Unknown action: $action" } unless $cmd;

            $cmd .= " 2>&1";
            my $output = `$cmd`;
            my $exit_code = $? >> 8;

            return {
                ok        => $exit_code == 0 ? 1 : 0,
                output    => $output,
                exit_code => $exit_code,
                action    => $action,
                dir       => $dir,
            };
        },
    );
}

1;
