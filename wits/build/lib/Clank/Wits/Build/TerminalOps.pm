# CLANK-WIT: name=TerminalOps
# CLANK-WIT: version=1.0.0
# CLANK-WIT: about=Evidence-first repo execution workflow — inspect, fix, verify, push
# CLANK-WIT: usage=Input: { path?: string, branch?: string, file?: string, test?: string, error?: string } Output: { surface?, preview?, report? }
# CLANK-WIT: hint=terminal ops, evidence first, repo execution, git state, inspect before edit, fix, verify, push
# CLANK-WIT: author=Clank
# CLANK-WIT: license=Artistic-2.0
package Clank::Wits::Build::TerminalOps;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'repo_surface',
        description => 'Resolve working surface: repo path, branch, local diff state, mode (inspect/fix/verify/push)',
        parameters  => {
            type       => 'object',
            properties => {
                path   => { type => 'string', description => 'Repo path (default: cwd)' },
                branch => { type => 'string', description => 'Branch name to check (default: current)' },
            },
            required => [],
        },
        execute => sub {
            my ($args) = @_;
            my $path   = $args->{path}   // '.';
            my $branch = $args->{branch};

            my $status = `git -C $path status --short --branch 2>&1`;
            my $log    = `git -C $path log --oneline -5 2>&1`;
            my $diff   = `git -C $path diff --stat 2>&1`;

            my $current_branch = '';
            if ($status =~ /^## (\S+)/m) {
                $current_branch = $1;
                $current_branch =~ s/\.\.\..*//;
            }

            my $mode = 'inspect';
            if ($status =~ /behind/) {
                $mode = 'push';
            }
            elsif ($diff =~ /\S/) {
                $mode = 'fix';
            }
            elsif ($status =~ /nothing to commit/) {
                $mode = 'verify';
            }

            return {
                repo        => $path,
                branch      => $branch // $current_branch,
                status      => $status,
                log         => $log,
                diff_stat   => $diff,
                mode        => $mode,
            };
        },
    );

    $api->register_tool(
        name        => 'repo_inspect',
        description => 'Inspect a failing surface before editing — read file, check git state, find related tests',
        parameters  => {
            type       => 'object',
            properties => {
                path  => { type => 'string', description => 'Repo path (default: cwd)' },
                file  => { type => 'string', description => 'File to inspect' },
                test  => { type => 'string', description => 'Failing test name or path' },
                error => { type => 'string', description => 'Error output to analyze' },
            },
            required => [],
        },
        execute => sub {
            my ($args) = @_;
            my $path  = $args->{path}  // '.';
            my $file  = $args->{file};
            my $test  = $args->{test};
            my $error = $args->{error};

            my $preview = '';
            if ($file && -f "$path/$file") {
                open my $fh, '<', "$path/$file" or return { error => "Cannot read $file: $!" };
                my $count = 0;
                while (<$fh>) {
                    $preview .= $_;
                    last if ++$count >= 50;
                }
                close $fh;
            }

            my $git_state = `git -C $path status --short 2>&1`;

            my @related_tests;
            if ($file) {
                (my $basename = $file) =~ s{.*/}{};
                $basename =~ s/\.pm$//;
                my $t_dir = "$path/t";
                if (-d $t_dir) {
                    opendir my $dh, $t_dir or return { error => "Cannot open t/: $!" };
                    while (my $f = readdir $dh) {
                        next unless $f =~ /test|\.t$/i;
                        next if $f eq '.' || $f eq '..';
                        if (-f "$t_dir/$f") {
                            open my $tfh, '<', "$t_dir/$f" or next;
                            my $content = do { local $/; <$tfh> };
                            close $tfh;
                            push @related_tests, "$t_dir/$f" if $content =~ /\Q$basename\E/i;
                        }
                    }
                    closedir $dh;
                }
            }

            return {
                content_preview => $preview,
                git_state       => $git_state,
                related_tests   => \@related_tests,
                file            => $file,
                test            => $test,
                error           => $error,
            };
        },
    );

    $api->register_tool(
        name        => 'repo_report',
        description => 'Produce evidence report with exact status in SURFACE/EVIDENCE/ACTION/STATUS format',
        parameters  => {
            type       => 'object',
            properties => {
                surface  => { type => 'object', description => 'Surface object from repo_surface' },
                evidence => { type => 'string', description => 'Evidence of what was done or observed' },
                action   => { type => 'string', description => 'Action taken or planned' },
                status   => {
                    type    => 'string',
                    enum    => [qw(inspect changed_locally verified_locally committed pushed blocked)],
                    description => 'Current execution state',
                },
            },
            required => [qw(evidence action status)],
        },
        execute => sub {
            my ($args) = @_;
            my $surface  = $args->{surface}  // {};
            my $evidence = $args->{evidence} // '';
            my $action   = $args->{action}   // '';
            my $status   = $args->{status}   // 'inspect';

            my $repo   = $surface->{repo}   // 'unknown';
            my $branch = $surface->{branch} // 'unknown';
            my $mode   = $surface->{mode}   // 'inspect';

            my $report = '';
            $report .= "=== EVIDENCE REPORT ===\n";
            $report .= "SURFACE:  $repo ($branch) mode=$mode\n";
            $report .= "EVIDENCE: $evidence\n";
            $report .= "ACTION:   $action\n";
            $report .= "STATUS:   $status\n";
            $report .= "=======================\n";

            return {
                report  => $report,
                status  => $status,
                surface => $repo,
            };
        },
    );
}

1;
