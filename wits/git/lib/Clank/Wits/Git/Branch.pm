# CLANK-WIT: name=Branch
# CLANK-WIT: version=1.0.0
# CLANK-WIT: about=List branches or create new branch
# CLANK-WIT: usage=Input: { path: ".", action: "list" } Input: { path: ".", action: "create", name: "feature-x" } Output: { branches: [...], current: "main" }
# CLANK-WIT: hint=git branch, list branches, create branch, checkout, switch
# CLANK-WIT: author=Clank
# CLANK-WIT: license=Artistic-2.0
package Clank::Wits::Git::Branch;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'git_branch',
        description => 'List branches or create new branch',
        parameters  => {
            type       => 'object',
            properties => {
                path   => { type => 'string', description => 'Repository path', default => '.' },
                action => { type => 'string', description => 'Action: list, create, checkout, switch, delete', default => 'list' },
                name   => { type => 'string', description => 'Branch name' },
            },
        },
        execute => sub {
            my ($args) = @_;
            my $path = $args->{path} // '.';
            my $action = $args->{action} // 'list';
            my $name = $args->{name} // '';

            if ($action eq 'list') {
                my $output = `cd '$path' && git branch 2>/dev/null`;
                my @branches;
                my $current;
                for my $line (split /\n/, $output) {
                    if ($line =~ /^\*\s+(.+)$/) {
                        $current = $1;
                        push @branches, $1;
                    } elsif ($line =~ /^\s+(.+)$/) {
                        push @branches, $1;
                    }
                }
                return {
                    branches => \@branches,
                    current  => $current,
                    count    => scalar @branches,
                };
            }

            if ($action eq 'create') {
                return { error => "No branch name provided" } unless $name;
                my $output = `cd '$path' && git checkout -b '$name' 2>&1`;
                my $exit = $? >> 8;
                return { error => "Create failed: $output" } if $exit != 0;
                return { ok => 1, branch => $name };
            }

            if ($action eq 'checkout' || $action eq 'switch') {
                return { error => "No branch name provided" } unless $name;
                my $output = `cd '$path' && git checkout '$name' 2>&1`;
                my $exit = $? >> 8;
                return { error => "Switch failed: $output" } if $exit != 0;
                return { ok => 1, branch => $name };
            }

            if ($action eq 'delete') {
                return { error => "No branch name provided" } unless $name;
                my $output = `cd '$path' && git branch -d '$name' 2>&1`;
                my $exit = $? >> 8;
                return { error => "Delete failed: $output" } if $exit != 0;
                return { ok => 1, branch => $name };
            }

            return { error => "Unknown action: $action" };
        },
    );
}

1;
