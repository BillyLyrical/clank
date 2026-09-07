# CLAM-WIT: name=Log
# CLAM-WIT: version=1.0.0
# CLAM-WIT: about=Show git log with stats, author breakdown, and date filtering
# CLAM-WIT: usage=Input: { path: ".", count: 10 } Output: { commits: [...], by_author: {...}, summary: {...} }
# CLAM-WIT: hint=git log, commit history, author stats, date range
# CLAM-WIT: author=CLAM
# CLAM-WIT: license=Artistic-2.0
package AI::Clam::Wits::Git::Log;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'git_log',
        description => 'Show git log with stats, author breakdown, and date filtering',
        parameters  => {
            type       => 'object',
            properties => {
                path   => { type => 'string', description => 'Repository path', default => '.' },
                count  => { type => 'integer', description => 'Number of commits', default => 10 },
                author => { type => 'string', description => 'Filter by author' },
                since  => { type => 'string', description => 'Show commits since date' },
                until  => { type => 'string', description => 'Show commits until date' },
                file   => { type => 'string', description => 'Filter by file path' },
            },
        },
        execute => sub {
            my ($args) = @_;
            my $path = $args->{path} // '.';
            my $count = $args->{count} // 10;
            my $author = $args->{author} // '';
            my $since = $args->{since} // '';
            my $until = $args->{until} // '';
            my $file = $args->{file} // '';

            my @cmd = ("cd", $path, "&&", "git", "log", q{--pretty='format:%H|%h|%an|%ae|%ai|%s'}, "-n", $count);
            push @cmd, ("--author=$author") if $author;
            push @cmd, ("--since=$since") if $since;
            push @cmd, ("--until=$until") if $until;
            push @cmd, ("--", $file) if $file;

            my $cmd_str = join(" ", @cmd);
            my $output = `$cmd_str 2>/dev/null`;
            my $exit = $? >> 8;

            return { error => "Not a git repository" } if $exit != 0 && !$output;

            my @commits;
            my %by_author;
            my %by_date;

            for my $line (split /\n/, $output) {
                if ($line =~ /^([0-9a-f]{40})\|([0-9a-f]+)\|(.+?)\|(.+?)\|(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}\s+[+-]\d{4})\|(.*)$/) {
                    my $commit = {
                        hash    => $1,
                        short   => $2,
                        author  => $3,
                        email   => $4,
                        date    => $5,
                        message => $6,
                    };
                    push @commits, $commit;

                    my $auth = $3;
                    $by_author{$auth} //= { commits => 0, lines_added => 0, lines_deleted => 0, files_changed => 0 };
                    $by_author{$auth}{commits}++;

                    my ($date_only) = split(/\s+/, $5);
                    $by_date{$date_only} //= 0;
                    $by_date{$date_only}++;

                    my $stat = `cd '$path' && git diff-tree --stat --no-commit-id -r $1 2>/dev/null`;
                    if ($stat) {
                        my $added = 0;
                        my $deleted = 0;
                        my $files = 0;
                        for my $sline (split /\n/, $stat) {
                            if ($sline =~ /\d+\s+insertion/) { $added += $1 if $sline =~ /(\d+)\s+insertion/; }
                            if ($sline =~ /\d+\s+deletion/) { $deleted += $1 if $sline =~ /(\d+)\s+deletion/; }
                            $files++ if $sline =~ /\|/;
                        }
                        $commit->{additions} = $added;
                        $commit->{deletions} = $deleted;
                        $commit->{files_changed} = $files;
                        $by_author{$auth}{lines_added} += $added;
                        $by_author{$auth}{lines_deleted} += $deleted;
                        $by_author{$auth}{files_changed} += $files;
                    }
                }
            }

            my $total_commits = scalar @commits;
            for my $auth (keys %by_author) {
                $by_author{$auth}{pct} = $total_commits > 0 ? sprintf("%.1f", ($by_author{$auth}{commits} / $total_commits) * 100) : 0;
            }

            my @sorted_authors = sort { $by_author{$b}{commits} <=> $by_author{$a}{commits} } keys %by_author;

            my $branch = `cd '$path' && git branch --show-current 2>/dev/null` || 'unknown';
            chomp $branch;

            return {
                path      => $path,
                branch    => $branch,
                commits   => \@commits,
                count     => $total_commits,
                by_author => { map { $_ => $by_author{$_} } @sorted_authors },
                by_date   => \%by_date,
                summary   => {
                    total_commits  => $total_commits,
                    unique_authors => scalar keys %by_author,
                    top_author     => $sorted_authors[0] || 'unknown',
                    top_author_pct => $by_author{$sorted_authors[0]}{pct} || 0,
                    date_range     => {
                        from => $commits[-1]{date} // 'unknown',
                        to   => $commits[0]{date} // 'unknown',
                    },
                },
            };
        },
    );
}

1;
