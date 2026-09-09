# CLANK-WIT: name=DockerLogs
# CLANK-WIT: version=1.0.0
# CLANK-WIT: about=View Docker container logs with tail and follow
# CLANK-WIT: usage=Input: { container: "web", tail: 100, follow: false } Output: { ok: true, logs: "..." }
# CLANK-WIT: hint=docker logs, container output, docker follow, container debugging
# CLANK-WIT: author=Clank
# CLANK-WIT: license=Artistic-2.0
package Clank::Wits::Devops::DockerLogs;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;
    $api->register_tool(
        name        => 'docker_logs',
        description => 'View Docker container logs with tail and follow',
        parameters  => {
            type       => 'object',
            properties => {
                container => { type => 'string', description => 'Container name or ID' },
                tail      => { type => 'integer', description => 'Number of lines from end', default => 100 },
                follow    => { type => 'boolean', description => 'Follow log output', default => 0 },
                since     => { type => 'string', description => 'Show logs since timestamp' },
                timestamps => { type => 'boolean', description => 'Show timestamps', default => 0 },
            },
            required => ['container'],
        },
        execute => sub {
            my ($args) = @_;
            my $container  = $args->{container}  // '';
            my $tail       = $args->{tail}       // 100;
            my $follow     = $args->{follow}     // 0;
            my $since      = $args->{since}      // '';
            my $timestamps = $args->{timestamps} // 0;

            return { error => "No container specified" } unless $container;

            my $cmd = "docker logs";
            $cmd .= " --tail $tail";
            $cmd .= " -f" if $follow;
            $cmd .= " --since $since" if $since;
            $cmd .= " -t" if $timestamps;
            $cmd .= " $container 2>&1";

            my $output = `$cmd`;
            my $exit_code = $? >> 8;

            if ($exit_code != 0) {
                return { error => "docker logs failed: $output", exit_code => $exit_code };
            }

            return {
                ok        => 1,
                logs      => $output,
                container => $container,
                lines     => ($output =~ tr/\n//) + 1,
            };
        },
    );
}

1;
