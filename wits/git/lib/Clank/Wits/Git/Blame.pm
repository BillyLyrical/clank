# CLANK-WIT: name=Blame
# CLANK-WIT: version=1.0.0
# CLANK-WIT: about=Show git blame with author stats and ownership breakdown
# CLANK-WIT: usage=Input: { path: ".", file: "lib/Clank/Core.pm" } Output: { lines: [...], by_author: {...}, stats: {...} }
# CLANK-WIT: hint=git blame, line ownership, author stats, code history
# CLANK-WIT: author=Clank
# CLANK-WIT: license=Artistic-2.0
package Clank::Wits::Git::Blame;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'git_blame',
        description => 'Show git blame with author stats and ownership breakdown',
        parameters  => {
            type       => 'object',
            properties => {
                path => { type => 'string', description => 'Repository path', default => '.' },
                file => { type => 'string', description => 'File to blame' },
            },
            required => ['file'],
        },
        execute => sub {
            my ($args) = @_;
            my $path = $args->{path} // '.';
            my $file = $args->{file} // '';

            return { error => "No file provided" } unless $file;

            my $output = `cd '$path' && git blame --porcelain '$file' 2>/dev/null`;
            my $exit = $? >> 8;

            return { error => "Blame failed" } if $exit != 0;

            my @lines;
            my $current;
            my %by_author;
            my %by_hash;

            for my $line (split /\n/, $output) {
                if ($line =~ /^([0-9a-f]+)\s+(\d+)\s+(\d+)\s+(\d+)/) {
                    $current = {
                        hash    => substr($1, 0, 8),
                        line    => $2,
                        author  => '',
                        date    => '',
                        epoch   => 0,
                        content => '',
                    };
                } elsif ($line =~ /^author\s+(.+)$/) {
                    $current->{author} = $1 if $current;
                } elsif ($line =~ /^author-time\s+(\d+)$/) {
                    if ($current) {
                        $current->{epoch} = $1;
                        $current->{date} = scalar localtime($1);
                    }
                } elsif ($line =~ /^\t(.*)$/) {
                    $current->{content} = $1 if $current;
                    if ($current) {
                        push @lines, $current;

                        my $auth = $current->{author};
                        $by_author{$auth} //= { lines => 0, first_date => $current->{date}, last_date => $current->{date}, commits => {} };
                        $by_author{$auth}{lines}++;
                        $by_author{$auth}{first_date} = $current->{date} if $current->{epoch} < ($by_author{$auth}{first_epoch} // 9999999999);
                        $by_author{$auth}{last_date} = $current->{date} if $current->{epoch} > ($by_author{$auth}{last_epoch} // 0);
                        $by_author{$auth}{first_epoch} = $current->{epoch} if !exists $by_author{$auth}{first_epoch} || $current->{epoch} < $by_author{$auth}{first_epoch};
                        $by_author{$auth}{last_epoch} = $current->{epoch} if !exists $by_author{$auth}{last_epoch} || $current->{epoch} > $by_author{$auth}{last_epoch};
                        $by_author{$auth}{commits}{$current->{hash}} = 1;

                        $by_hash{$current->{hash}} //= { author => $auth, lines => 0 };
                        $by_hash{$current->{hash}}{lines}++;
                    }
                    $current = undef;
                }
            }

            my $total_lines = scalar @lines;
            for my $auth (keys %by_author) {
                my $a = $by_author{$auth};
                $a->{pct} = $total_lines > 0 ? sprintf("%.1f", ($a->{lines} / $total_lines) * 100) : 0;
                $a->{unique_commits} = scalar keys %{$a->{commits}};
                delete $a->{commits};
                delete $a->{first_epoch};
                delete $a->{last_epoch};
            }

            my @sorted_authors = sort { $by_author{$b}{lines} <=> $by_author{$a}{lines} } keys %by_author;

            my @commits;
            for my $hash (sort { $by_hash{$b}{lines} <=> $by_hash{$a}{lines} } keys %by_hash) {
                push @commits, {
                    hash   => $hash,
                    author => $by_hash{$hash}{author},
                    lines  => $by_hash{$hash}{lines},
                };
            }

            return {
                file      => $file,
                lines     => \@lines,
                count     => $total_lines,
                by_author => { map { $_ => $by_author{$_} } @sorted_authors },
                by_commit => \@commits,
                summary   => {
                    total_lines    => $total_lines,
                    unique_authors => scalar keys %by_author,
                    unique_commits => scalar keys %by_hash,
                    top_author     => $sorted_authors[0] || 'unknown',
                    top_author_lines => $by_author{$sorted_authors[0]}{lines} || 0,
                    top_author_pct   => $by_author{$sorted_authors[0]}{pct} || 0,
                },
            };
        },
    );
}

1;
