# CLANK-WIT: name=DockerPs
# CLANK-WIT: version=1.0.0
# CLANK-WIT: about=List Docker containers with filtering
# CLANK-WIT: usage=Input: { all: true, format: "table" } Output: { containers: [{ id: "...", name: "...", status: "...", image: "..." }] }
# CLANK-WIT: hint=docker ps, list containers, docker list, container status
# CLANK-WIT: author=Clank
# CLANK-WIT: license=Artistic-2.0
package Clank::Wits::Devops::DockerPs;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;
    $api->register_tool(
        name        => 'docker_ps',
        description => 'List Docker containers with filtering',
        parameters  => {
            type       => 'object',
            properties => {
                all    => { type => 'boolean', description => 'Show all containers (not just running)', default => 0 },
                filter => { type => 'string', description => 'Filter output (e.g. "status=exited")' },
                limit  => { type => 'integer', description => 'Max containers to show' },
            },
            required => [],
        },
        execute => sub {
            my ($args) = @_;
            my $all    = $args->{all}    ? '-a' : '';
            my $filter = $args->{filter} // '';
            my $limit  = $args->{limit}  // '';

            my $cmd = "docker ps $all --format '{{.ID}}|{{.Names}}|{{.Status}}|{{.Image}}|{{.Ports}}'";
            $cmd .= " --filter $filter" if $filter;
            $cmd .= " --limit $limit" if $limit;
            $cmd .= " 2>&1";

            my $output = `$cmd`;
            my $exit_code = $? >> 8;

            if ($exit_code != 0) {
                return { error => "docker ps failed: $output", exit_code => $exit_code };
            }

            my @containers;
            for my $line (split /\n/, $output) {
                my ($id, $name, $status, $image, $ports) = split /\|/, $line, 5;
                push @containers, {
                    id     => $id,
                    name   => $name,
                    status => $status,
                    image  => $image,
                    ports  => $ports,
                } if $id;
            }

            return {
                ok         => 1,
                containers => \@containers,
                count      => scalar @containers,
            };
        },
    );
}

1;
