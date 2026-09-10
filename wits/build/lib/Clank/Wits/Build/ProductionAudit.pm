# CLANK-WIT: name=ProductionAudit
# CLANK-WIT: version=1.0.0
# CLANK-WIT: about=Run a local-evidence production readiness audit on a codebase
# CLANK-WIT: usage=Input: { path?: string, branch?: string } Output: { score, band, summary, blockers, high_value_fixes, evidence_checked, evidence_missing, next_action }
# CLANK-WIT: hint=production audit, readiness, ship, deploy, risk, security, data integrity, operations, score
# CLANK-WIT: author=Clank
# CLANK-WIT: license=Artistic-2.0
package Clank::Wits::Build::ProductionAudit;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;
    $api->register_tool(
        name        => 'production_audit',
        description => 'Run a local-evidence production readiness audit on a codebase',
        parameters  => {
            type       => 'object',
            properties => {
                path   => { type => 'string', description => 'Project root directory (defaults to cwd)' },
                branch => { type => 'string', description => 'Branch to audit (defaults to current branch)' },
            },
            required => [],
        },
        execute => sub {
            my ($args) = @_;
            my $path = $args->{path} // '.';
            unless (-d $path) {
                return { error => "Directory $path does not exist" };
            }

            my $evidence = _gather_evidence($path);
            my ($score, $blockers) = _score($evidence);
            my $band = _band($score);
            my $high_value_fixes = _high_value_fixes($evidence);
            my $next_action = _next_action($score, $blockers, $high_value_fixes);

            return {
                score            => $score,
                band             => $band,
                summary          => _summary($score, $band, $evidence),
                blockers         => $blockers,
                high_value_fixes => $high_value_fixes,
                evidence_checked => $evidence->{checked},
                evidence_missing => $evidence->{missing},
                next_action      => $next_action,
            };
        },
    );
}

sub _gather_evidence {
    my ($path) = @_;
    my %e;

    $e{git_status}      = _git_cmd($path, 'status --porcelain');
    $e{has_uncommitted} = ($e{git_status} ne '') ? 1 : 0;
    $e{current_branch}  = _git_cmd($path, 'branch --show-current');
    $e{recent_commits}  = _git_cmd($path, 'log --oneline -10');
    $e{diff_stat}       = _git_cmd($path, 'diff --stat HEAD~5..HEAD 2>/dev/null');
    $e{commit_count_5}  = scalar split /\n/, $e{recent_commits};

    my @file_checks = qw(
        Dockerfile docker-compose.yml docker-compose.yaml
        .github/workflows .gitlab-ci.yml Jenkinsfile
        Makefile cpanfile dist.ini
    );
    for my $f (@file_checks) {
        (my $key = $f) =~ s{[/.]}{_}g;
        $e{"has_$key"} = (-e "$path/$f") ? 1 : 0;
    }

    $e{has_t_dir}       = (-d "$path/t") ? 1 : 0;
    $e{has_migrations}  = (-d "$path/migrations" || -d "$path/db/migrate" ||
                           -d "$path/sql" || _has_migr_files($path)) ? 1 : 0;
    $e{has_env_docs}    = (-f "$path/.env.example" || -f "$path/.env.sample" ||
                           -f "$path/env.example"  || -f "$path/ENV.example") ? 1 : 0;
    $e{has_readme}      = (-f "$path/README.md" || -f "$path/README" ||
                           -f "$path/README.pod") ? 1 : 0;

    $e{auth_present}     = _check_auth($path);
    $e{secrets_exposed}  = _check_secrets($path);
    $e{rollback_docs}    = _check_rollback($path);
    $e{idempotent_hooks} = _check_webhook_idempotency($path);
    $e{ci_config}        = _check_ci_config($path);
    $e{test_files_count} = _count_test_files($path);

    $e{checked} = [];
    $e{missing} = [];

    my @evidence_items = (
        ['git_clean',       !$e{has_uncommitted}],
        ['commits_present',  $e{commit_count_5} > 0],
        ['ci_config',        $e{ci_config}],
        ['tests_exist',      $e{has_t_dir}],
        ['migrations_safe', !$e{has_migrations} || $e{has_env_docs}],
        ['env_docs',         $e{has_env_docs}],
        ['rollback_plan',    $e{rollback_docs}],
        ['auth_checked',     $e{auth_present}],
        ['secrets_clean',   !$e{secrets_exposed}],
        ['readme',           $e{has_readme}],
    );

    for my $item (@evidence_items) {
        my ($name, $ok) = @$item;
        push @{$ok ? $e{checked} : $e{missing}}, $name;
    }

    return \%e;
}

sub _has_migr_files {
    my ($path) = @_;
    for my $dir ("$path/db", "$path/lib") {
        next unless -d $dir;
        my @m = glob("$dir/**/*.sql");
        return 1 if @m;
    }
    return 0;
}

sub _check_auth {
    my ($path) = @_;
    for my $f (_pm_files($path)) {
        open my $fh, '<', $f or next;
        while (<$fh>) {
            return 1 if /auth|session|token|login|password|credential/i;
        }
        close $fh;
    }
    return 0;
}

sub _check_secrets {
    my ($path) = @_;
    for my $f (_pm_files($path)) {
        open my $fh, '<', $f or next;
        while (<$fh>) {
            return 1 if /(?:password|secret|api_key|apikey|token)\s*=\s*['"][^'"]+['"]/i;
        }
        close $fh;
    }
    return 0;
}

sub _check_rollback {
    my ($path) = @_;
    for my $f (qw(ROLLBACK.md rollback.md docs/rollback.md DEPLOY.md deploy.md ops/rollback.md)) {
        return 1 if -f "$path/$f";
    }
    return 0;
}

sub _check_webhook_idempotency {
    my ($path) = @_;
    for my $f (_pm_files($path)) {
        open my $fh, '<', $f or next;
        while (<$fh>) {
            return 0 if /webhook/i && !/idempoten/i;
        }
        close $fh;
    }
    return 1;
}

sub _check_ci_config {
    my ($path) = @_;
    return 1 if glob("$path/.github/workflows/*.yml") || glob("$path/.github/workflows/*.yaml");
    return (-f "$path/.gitlab-ci.yml" || -f "$path/Jenkinsfile" || -f "$path/Makefile") ? 1 : 0;
}

sub _pm_files {
    my ($path) = @_;
    my @pm;
    for my $dir (grep { -d $_ } "$path/lib", $path) {
        open my $fh, '-|', "find $dir -name '*.pm' -type f 2>/dev/null" or next;
        while (<$fh>) { chomp; push @pm, $_ }
        close $fh;
    }
    return @pm;
}

sub _count_test_files {
    my ($path) = @_;
    my @t = glob("$path/t/*.t");
    return scalar @t;
}

sub _score {
    my ($e) = @_;
    my $score = 100;
    my @blockers;

    if (!$e->{auth_present}) {
        $score = 69;
        push @blockers, 'No authentication/authorization patterns detected in codebase';
    }
    if (!$e->{idempotent_hooks}) {
        $score = 69 if $score > 69;
        push @blockers, 'Webhook handlers lack idempotency guarantees';
    }
    if ($e->{secrets_exposed}) {
        $score = 69 if $score > 69;
        push @blockers, 'Hardcoded secrets or credentials detected in source';
    }
    if (!$e->{rollback_docs}) {
        $score = 69 if $score > 69;
        push @blockers, 'No rollback documentation found';
    }
    if ($e->{has_migrations} && !$e->{has_env_docs}) {
        $score = 69 if $score > 69;
        push @blockers, 'Database migrations present without environment documentation';
    }
    if (!$e->{ci_config}) {
        $score = 84 if $score > 84;
        push @blockers, 'No CI configuration detected';
    }
    if (!$e->{test_files_count} || $e->{test_files_count} == 0) {
        $score = 84 if $score > 84;
        push @blockers, 'No test files found';
    }

    return ($score, \@blockers);
}

sub _band {
    my ($score) = @_;
    return 'Blocked'                 if $score <= 49;
    return 'Risky'                   if $score <= 69;
    return 'Launchable With Caveats' if $score <= 84;
    return 'Strong';
}

sub _high_value_fixes {
    my ($e) = @_;
    my @fixes;
    push @fixes, 'Add authentication and authorization layer'   unless $e->{auth_present};
    push @fixes, 'Implement webhook idempotency keys'           unless $e->{idempotent_hooks};
    push @fixes, 'Remove hardcoded secrets; use env vars'       if $e->{secrets_exposed};
    push @fixes, 'Add rollback/deployment documentation'        unless $e->{rollback_docs};
    push @fixes, 'Add .env.example for configuration reference' unless $e->{has_env_docs};
    push @fixes, 'Add CI pipeline configuration'               unless $e->{ci_config};
    push @fixes, 'Add test suite in t/'                        unless $e->{test_files_count};
    push @fixes, 'Commit uncommitted changes'                  if $e->{has_uncommitted};
    return \@fixes;
}

sub _next_action {
    my ($score, $blockers, $fixes) = @_;
    return 'Address all blockers before considering deployment' if $score <= 49;
    return $blockers->[0] if @$blockers;
    return $fixes->[0]    if @$fixes;
    return 'Codebase looks ready for production — consider a final review';
}

sub _summary {
    my ($score, $band, $e) = @_;
    my $checked = scalar @{$e->{checked}};
    my $missing = scalar @{$e->{missing}};
    return "$score/100 ($band) — $checked evidence items checked, $missing missing";
}

sub _git_cmd {
    my ($dir, $cmd) = @_;
    my $output = `cd $dir && git $cmd 2>/dev/null`;
    chomp $output if defined $output;
    return $output // '';
}

1;
