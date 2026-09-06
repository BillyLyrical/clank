# CLAM-WIT: name=Ignore
# CLAM-WIT: version=1.0.0
# CLAM-WIT: about=Manage .gitignore file
# CLAM-WIT: usage=Input: { path: ".", action: "list" } Input: { path: ".", action: "add", pattern: "*.log" } Output: { patterns: [...], added: true }
# CLAM-WIT: hint=gitignore, ignore patterns, exclude files from tracking
# CLAM-WIT: author=CLAM
# CLAM-WIT: license=Artistic-2.0
package Clam::Wits::Git::Ignore;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'git_ignore',
        description => 'Manage .gitignore file',
        parameters  => {
            type       => 'object',
            properties => {
                path    => { type => 'string', description => 'Repository path', default => '.' },
                action  => { type => 'string', description => 'Action: list, add', default => 'list' },
                pattern => { type => 'string', description => 'Pattern to add' },
            },
        },
        execute => sub {
            my ($args) = @_;
            my $path = $args->{path} // '.';
            my $action = $args->{action} // 'list';
            my $pattern = $args->{pattern} // '';

            my $gitignore = "$path/.gitignore";

            if ($action eq 'list') {
                return { patterns => [], file => $gitignore } unless -f $gitignore;

                open my $fh, '<', $gitignore or return { error => "Cannot read: $!" };
                my @patterns = grep { /\S/ && !/^\s*#/ } <$fh>;
                close $fh;
                chomp @patterns;

                return {
                    patterns => \@patterns,
                    count    => scalar @patterns,
                    file     => $gitignore,
                };
            }

            if ($action eq 'add') {
                return { error => "No pattern provided" } unless $pattern;

                if (-f $gitignore) {
                    open my $fh, '<', $gitignore;
                    my @existing = <$fh>;
                    close $fh;
                    chomp @existing;
                    if (grep { $_ eq $pattern } @existing) {
                        return { ok => 1, message => "Pattern already exists" };
                    }
                }

                open my $fh, '>>', $gitignore or return { error => "Cannot write: $!" };
                print $fh "$pattern\n";
                close $fh;

                return {
                    ok      => 1,
                    pattern => $pattern,
                    action  => 'added',
                };
            }

            return { error => "Unknown action: $action" };
        },
    );
}

1;
