# CLANK-WIT: name=Make
# CLANK-WIT: version=1.0.0
# CLANK-WIT: about=Run make targets with configurable job count
# CLANK-WIT: usage=Input: { target: "all", jobs: 4, dir: "/path/to/project" } Output: { ok: true, output: "...", exit_code: 0 }
# CLANK-WIT: hint=make build compile, makefile, targets, build system
# CLANK-WIT: author=Clank
# CLANK-WIT: license=Artistic-2.0
package Clank::Wits::Build::Make;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;
    $api->register_tool(
        name        => 'build_make',
        description => 'Run make targets with configurable job count',
        parameters  => {
            type       => 'object',
            properties => {
                target => { type => 'string', description => 'Make target', default => 'all' },
                jobs   => { type => 'integer', description => 'Parallel jobs (-j)', default => 1 },
                dir    => { type => 'string', description => 'Working directory' },
                env    => { type => 'object', description => 'Environment variables' },
            },
            required => [],
        },
        execute => sub {
            my ($args) = @_;
            my $target = $args->{target} // 'all';
            my $jobs   = $args->{jobs}   // 1;
            my $dir    = $args->{dir}    // '.';
            my $env    = $args->{env}    // {};

            return { error => "Directory not found: $dir" } unless -d $dir;
            return { error => "No Makefile in $dir" } unless -f "$dir/Makefile" || -f "$dir/makefile";

            my $cmd = "make -C $dir -j$jobs $target 2>&1";
            for my $k (keys %$env) {
                $cmd = "$k=$env->{$k} $cmd";
            }

            my $output = `$cmd`;
            my $exit_code = $? >> 8;

            return {
                ok        => $exit_code == 0 ? 1 : 0,
                output    => $output,
                exit_code => $exit_code,
                target    => $target,
                dir       => $dir,
            };
        },
    );
}

1;
