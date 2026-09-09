# CLANK-WIT: name=Stash
# CLANK-WIT: version=1.0.0
# CLANK-WIT: about=Stash changes
# CLANK-WIT: usage=Input: { path: ".", action: "save", message: "work in progress" } Input: { path: ".", action: "list" } Input: { path: ".", action: "pop" } Output: { ok: true, stash: "stash@{0}" }
# CLANK-WIT: hint=git stash, save changes, restore stashed changes
# CLANK-WIT: author=Clank
# CLANK-WIT: license=Artistic-2.0
package Clank::Wits::Git::Stash;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'git_stash',
        description => 'Stash changes',
        parameters  => {
            type       => 'object',
            properties => {
                path    => { type => 'string', description => 'Repository path', default => '.' },
                action  => { type => 'string', description => 'Action: save, list, pop, drop', default => 'save' },
                message => { type => 'string', description => 'Stash message' },
            },
        },
        execute => sub {
            my ($args) = @_;
            my $path = $args->{path} // '.';
            my $action = $args->{action} // 'save';
            my $message = $args->{message} // '';

            if ($action eq 'save') {
                my $cmd = "cd '$path' && git stash push";
                $cmd .= " -m '$message'" if $message;
                my $output = `$cmd 2>&1`;
                my $exit = $? >> 8;
                return { error => "Stash failed: $output" } if $exit != 0;
                return { ok => 1, message => $message || "Changes stashed" };
            }

            if ($action eq 'list') {
                my $output = `cd '$path' && git stash list 2>/dev/null`;
                my @stashes;
                for my $line (split /\n/, $output) {
                    if ($line =~ /^(stash@\{(\d+)\}): (.+)$/) {
                        push @stashes, {
                            ref     => $1,
                            index   => $2,
                            message => $3,
                        };
                    }
                }
                return { stashes => \@stashes, count => scalar @stashes };
            }

            if ($action eq 'pop') {
                my $output = `cd '$path' && git stash pop 2>&1`;
                my $exit = $? >> 8;
                return { error => "Pop failed: $output" } if $exit != 0;
                return { ok => 1, message => "Stash popped" };
            }

            if ($action eq 'drop') {
                my $output = `cd '$path' && git stash drop 2>&1`;
                my $exit = $? >> 8;
                return { error => "Drop failed: $output" } if $exit != 0;
                return { ok => 1, message => "Stash dropped" };
            }

            return { error => "Unknown action: $action" };
        },
    );
}

1;
