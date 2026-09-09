# CLANK-WIT: name=DockerRun
# CLANK-WIT: version=1.0.0
# CLANK-WIT: about=Run a Docker container with common options
# CLANK-WIT: usage=Input: { image: "nginx", name: "web", detach: true, ports: ["80:80"] } Output: { ok: true, container_id: "abc123" }
# CLANK-WIT: hint=docker run, start container, launch docker, deploy
# CLANK-WIT: author=Clank
# CLANK-WIT: license=Artistic-2.0
package Clank::Wits::Devops::DockerRun;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;
    $api->register_tool(
        name        => 'docker_run',
        description => 'Run a Docker container with common options',
        parameters  => {
            type       => 'object',
            properties => {
                image    => { type => 'string', description => 'Docker image to run' },
                name     => { type => 'string', description => 'Container name' },
                detach   => { type => 'boolean', description => 'Run in background', default => 1 },
                ports    => { type => 'array', description => 'Port mappings (e.g. ["80:80"])' },
                volumes  => { type => 'array', description => 'Volume mounts (e.g. ["/host:/container"])' },
                env      => { type => 'object', description => 'Environment variables' },
                command  => { type => 'string', description => 'Command to run' },
            },
            required => ['image'],
        },
        execute => sub {
            my ($args) = @_;
            my $image   = $args->{image}   // '';
            my $name    = $args->{name}    // '';
            my $detach  = $args->{detach}  // 1;
            my $ports   = $args->{ports}   // [];
            my $volumes = $args->{volumes} // [];
            my $env     = $args->{env}     // {};
            my $cmd     = $args->{command} // '';

            return { error => "No image specified" } unless $image;

            my $run = "docker run";
            $run .= " -d" if $detach;
            $run .= " --name $name" if $name;
            $run .= " -p $_" for @$ports;
            $run .= " -v $_" for @$volumes;
            $run .= " -e $_=$env->{$_}" for keys %$env;
            $run .= " $image";
            $run .= " $cmd" if $cmd;
            $run .= " 2>&1";

            my $output = `$run`;
            my $exit_code = $? >> 8;

            if ($exit_code != 0) {
                return { error => "docker run failed: $output", exit_code => $exit_code };
            }

            chomp $output;

            return {
                ok           => 1,
                container_id => $output,
                image        => $image,
                name         => $name,
            };
        },
    );
}

1;
