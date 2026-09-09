# CLANK-WIT: name=SystemdStatus
# CLANK-WIT: version=1.0.0
# CLANK-WIT: about=Check systemd service status, start, stop, restart
# CLANK-WIT: usage=Input: { service: "nginx", action: "status" } Output: { ok: true, status: "active (running)", output: "..." }
# CLANK-WIT: hint=systemd service, systemctl, service status, start stop restart
# CLANK-WIT: author=Clank
# CLANK-WIT: license=Artistic-2.0
package Clank::Wits::Devops::SystemdStatus;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;
    $api->register_tool(
        name        => 'systemd_status',
        description => 'Check systemd service status, start, stop, restart',
        parameters  => {
            type       => 'object',
            properties => {
                service => { type => 'string', description => 'Service name' },
                action  => { type => 'string', enum => ['status', 'start', 'stop', 'restart', 'enable', 'disable'], description => 'Action to perform', default => 'status' },
            },
            required => ['service'],
        },
        execute => sub {
            my ($args) = @_;
            my $service = $args->{service} // '';
            my $action  = $args->{action}  // 'status';

            return { error => "No service specified" } unless $service;
            return { error => "Invalid action: $action" } unless $action =~ /^(?:status|start|stop|restart|enable|disable)$/;

            my $cmd = "systemctl $action $service 2>&1";
            my $output = `$cmd`;
            my $exit_code = $? >> 8;

            my $status = '';
            if ($action eq 'status') {
                if ($output =~ /Active:\s+(.+)/) {
                    $status = $1;
                    $status =~ s/\s*\(.*?\)\s*$//;
                }
            }

            return {
                ok        => $exit_code == 0 ? 1 : 0,
                output    => $output,
                exit_code => $exit_code,
                service   => $service,
                action    => $action,
                status    => $status,
            };
        },
    );
}

1;
