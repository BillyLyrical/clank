# CLAM-WIT: name=Vars
# CLAM-WIT: version=1.0.0
# CLAM-WIT: about=Manage psh variables — list, get, set, clear, export
# CLAM-WIT: usage=Input: { action: "list" } or { action: "get", name: "auth" } or { action: "set", name: "x", value: "42" } Output: { vars: {...}, count: N }
# CLAM-WIT: hint=psh_vars, variables, list, get, set, clear
# CLAM-WIT: author=CLAM
# CLAM-WIT: license=Artistic-2.0
package AI::Clam::Wits::Psh::Vars;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'psh_vars',
        description => 'Manage psh variables — list, get, set, clear, export',
        parameters  => {
            type       => 'object',
            properties => {
                action => { type => 'string', description => 'Action: list, get, set, delete, clear, history, result' },
                name   => { type => 'string', description => 'Variable name' },
                value  => { type => 'string', description => 'Variable value (for set)' },
            },
            required => ['action'],
        },
        execute => sub {
            my ($args) = @_;
            my $action = $args->{action} // 'list';
            my $name = $args->{name} // '';
            my $value = $args->{value} // '';
            my %ctx = $args->{_ctx} ? %{$args->{_ctx}} : ();

            my $state = $ctx{state} // {};
            $state->{psh} //= { vars => {}, history => [], result => '' };
            my $vars = $state->{psh}{vars};

            if ($action eq 'list') {
                my %display;
                for my $k (sort keys %$vars) {
                    my $v = $vars->{$k};
                    $display{$k} = ref($v) ? ref($v) : "$v";
                }
                return {
                    topic => 'psh.vars',
                    vars  => \%display,
                    count => scalar keys %$vars,
                };
            }

            if ($action eq 'get') {
                return { error => "No variable name" } unless $name;
                my $val = $vars->{$name};
                return { error => "Variable not found: $name" } unless defined $val;

                return {
                    topic => 'psh.vars',
                    name  => $name,
                    value => ref($val) ? ref($val) : "$val",
                    ref   => ref($val),
                };
            }

            if ($action eq 'set') {
                return { error => "No variable name" } unless $name;
                $vars->{$name} = $value;

                return {
                    topic => 'psh.vars',
                    name  => $name,
                    value => "$value",
                    set   => 1,
                };
            }

            if ($action eq 'delete' || $action eq 'unset') {
                return { error => "No variable name" } unless $name;
                return { error => "Variable not found: $name" } unless exists $vars->{$name};

                delete $vars->{$name};

                return {
                    topic   => 'psh.vars',
                    name    => $name,
                    deleted => 1,
                };
            }

            if ($action eq 'clear') {
                my $count = scalar keys %$vars;
                $state->{psh}{vars} = {};

                return {
                    topic => 'psh.vars',
                    cleared => $count,
                };
            }

            if ($action eq 'history') {
                my $history = $state->{psh}{history} // [];
                return {
                    topic   => 'psh.vars',
                    history => [@$history[-20..-1]],
                    count   => scalar @$history,
                };
            }

            if ($action eq 'result') {
                return {
                    topic  => 'psh.vars',
                    result => $state->{psh}{result} // '',
                };
            }

            return { error => "Unknown action: $action" };
        },
    );
}

1;
