# CLAM-WIT: name=Grep
# CLAM-WIT: version=1.0.0
# CLAM-WIT: about=Search code in git repository
# CLAM-WIT: usage=Input: { path: ".", pattern: "function", branch: "main" } Output: { matches: [{file: "...", line: 123, content: "..."}] }
# CLAM-WIT: hint=git grep, search code, find pattern in tracked files
# CLAM-WIT: author=CLAM
# CLAM-WIT: license=Artistic-2.0
package AI::Clam::Wits::Git::Grep;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'git_grep',
        description => 'Search code in git repository',
        parameters  => {
            type       => 'object',
            properties => {
                path    => { type => 'string', description => 'Repository path', default => '.' },
                pattern => { type => 'string', description => 'Search pattern' },
                branch  => { type => 'string', description => 'Branch to search (default: all)' },
            },
            required => ['pattern'],
        },
        execute => sub {
            my ($args) = @_;
            my $path = $args->{path} // '.';
            my $pattern = $args->{pattern} // '';
            my $branch = $args->{branch} // '';

            return { error => "No pattern provided" } unless $pattern;

            my $cmd = "cd '$path' && git grep -n '$pattern'";
            $cmd .= " '$branch'" if $branch;
            my $output = `$cmd 2>/dev/null`;

            my @matches;
            for my $line (split /\n/, $output) {
                if ($line =~ /^(.+?):(\d+):(.+)$/) {
                    push @matches, {
                        file    => $1,
                        line    => $2,
                        content => $3,
                    };
                }
            }

            return {
                matches => \@matches,
                count   => scalar @matches,
                pattern => $pattern,
            };
        },
    );
}

1;
