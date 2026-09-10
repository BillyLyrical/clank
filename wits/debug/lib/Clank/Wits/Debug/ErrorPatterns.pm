# CLANK-WIT: name=ErrorPatterns
# CLANK-WIT: version=1.0.0
# CLANK-WIT: about=Review Perl code for error handling anti-patterns. Fail fast, typed errors, never swallow silently.
# CLANK-WIT: usage=Input: { file: "lib/App/Service.pm" } Output: { issues: [{severity, line, pattern, message, suggestion}], summary: string, score: number }
# CLANK-WIT: hint=error handling, eval, exception, retry, circuit breaker, fail fast, error patterns, $@, Carp
# CLANK-WIT: author=Clank
# CLANK-WIT: license=Artistic-2.0
package Clank::Wits::Debug::ErrorPatterns;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'error_patterns',
        description => 'Review a Perl file for error handling anti-patterns and score it',
        parameters  => {
            type       => 'object',
            properties => {
                file => { type => 'string', description => 'Path to Perl file to review' },
            },
            required => ['file'],
        },
        execute => sub {
            my ($args) = @_;
            my $file = $args->{file} // '';

            return { error => "No file provided" } unless $file;
            return { error => "File not found: $file" } unless -f $file;

            open my $fh, '<', $file or return { error => "Cannot open $file: $!" };
            my @lines = <$fh>;
            close $fh;

            my @issues;
            my $score = 100;

            for my $i (0 .. $#lines) {
                my $line = $lines[$i];
                my $num = $i + 1;
                chomp $line;

                if ($line =~ /\beval\s*\{/) {
                    my $eval_line = $num;
                    my $depth = 0;
                    my $end_i = $i;
                    for my $j ($i .. $#lines) {
                        my $l = $lines[$j];
                        while ($l =~ /([{}])/g) {
                            $depth++ if $1 eq '{';
                            $depth--;
                            if ($depth == 0) {
                                $end_i = $j;
                                last;
                            }
                        }
                        last if $depth == 0;
                    }
                    my $check_window = "";
                    for my $j ($end_i + 1 .. $#lines) {
                        last if $j > $end_i + 5;
                        $check_window .= $lines[$j];
                    }
                    unless ($check_window =~ /\$@/) {
                        push @issues, {
                            severity   => 'high',
                            line       => $eval_line,
                            pattern    => 'eval_no_error_check',
                            message    => 'eval block without checking $@',
                            suggestion => 'Always check $@ after eval { } — swallowed errors hide bugs',
                        };
                        $score -= 15;
                    }
                }

                if ($line =~ /\beval\s*["'][^"']*\$\@/) {
                    push @issues, {
                        severity   => 'medium',
                        line       => $num,
                        pattern    => 'eval_string_dollar_at',
                        message    => 'eval STRING with $@ — consider eval BLOCK instead',
                        suggestion => 'eval BLOCK is safer: no accidental code injection, proper scoping',
                    };
                    $score -= 5;
                }

                if ($line =~ /^\s*(my\s+)?\$\w+\s*=\s*`[^`]+`/ || $line =~ /^\s*system\s*\(/) {
                    unless ($line =~ /\$?(\?|EXIT)/) {
                        my $next = ($num < scalar @lines) ? $lines[$num] : '';
                        unless ($next =~ /\$?(\?|EXIT)/) {
                            push @issues, {
                                severity   => 'high',
                                line       => $num,
                                pattern    => 'system_no_exit_check',
                                message    => 'system/backtick call without checking exit code ($? >> 8)',
                                suggestion => 'Always check $? after system/backticks to detect failures',
                            };
                            $score -= 10;
                        }
                    }
                }

                if ($line =~ /\bdie\b/ && $line =~ /^\s*die\s+["'][^"']+["']\s*;/) {
                    unless ($line =~ /::/ || $line =~ /\$/) {
                        push @issues, {
                            severity   => 'low',
                            line       => $num,
                            pattern    => 'bare_die_no_context',
                            message    => 'die with bare string — no module/function context',
                            suggestion => 'Use die "module::function failed: $!" for traceable errors',
                        };
                        $score -= 3;
                    }
                }

                if ($line =~ /\bwarn\b/ && $line =~ /^\s*warn\s+["'][^"']+["']\s*;/) {
                    unless ($line =~ /::/ || $line =~ /\$/) {
                        push @issues, {
                            severity   => 'low',
                            line       => $num,
                            pattern    => 'bare_warn_no_context',
                            message    => 'warn with bare string — no module/function context',
                            suggestion => 'Use warn "module::function: $!" for traceable warnings',
                        };
                        $score -= 2;
                    }
                }

                if ($line =~ /\bopen\s*\(\s*\w+\s*,\s*["'][^"']*["']\s*,/) {
                    my $combined = $line;
                    for my $j ($num .. $#lines) {
                        last if $j > $num + 2;
                        $combined .= " " . $lines[$j];
                    }
                    unless ($combined =~ /or\s+(die|warn|return)/ || $combined =~ /\$\?\s*>>\s*8/) {
                        push @issues, {
                            severity   => 'high',
                            line       => $num,
                            pattern    => 'open_no_check',
                            message    => 'open() without checking return value',
                            suggestion => 'Use open(my $fh, "<", $file) or die "Cannot open $file: $!"',
                        };
                        $score -= 10;
                    }
                }

                if ($line =~ /\$dbh->\w+\(/ || $line =~ /\$sth->\w+\(/) {
                    my $combined = $line;
                    for my $j ($num .. $#lines) {
                        last if $j > $num + 2;
                        $combined .= " " . $lines[$j];
                    }
                    unless ($combined =~ /\$@|->err|eval|or\s+die|or\s+warn|RaiseError|PrintError|HandleError/) {
                        push @issues, {
                            severity   => 'medium',
                            line       => $num,
                            pattern    => 'dbi_no_error_check',
                            message    => 'DBI call without apparent error handling',
                            suggestion => 'Check $dbh->err or use RaiseError => 1 in connect',
                        };
                        $score -= 8;
                    }
                }

                if ($line =~ /\beval\s*\{\s*\}/ || $line =~ /\beval\s*\{\s*;\s*\}/) {
                    push @issues, {
                        severity   => 'high',
                        line       => $num,
                        pattern    => 'empty_eval',
                        message    => 'Empty eval block — silently swallowing everything',
                        suggestion => 'Remove empty eval or add proper error handling',
                    };
                    $score -= 20;
                }

                if ($line =~ /\bdo\s*\{\s*my\s+\$e\s*=\s*\$@/) {
                    push @issues, {
                        severity   => 'info',
                        line       => $num,
                        pattern    => 'error_captured',
                        message    => 'Error captured to variable — good practice',
                        suggestion => 'Consider using Carp::longmess for full stack trace',
                    };
                }
            }

            $score = 0 if $score < 0;

            my $total = scalar @issues;
            my $high = grep { $_->{severity} eq 'high' } @issues;
            my $medium = grep { $_->{severity} eq 'medium' } @issues;
            my $low = grep { $_->{severity} eq 'low' } @issues;

            my $summary;
            if ($total == 0) {
                $summary = "No error handling issues found. Score: $score/100";
            } else {
                $summary = sprintf(
                    "Found %d issues (%d high, %d medium, %d low). Score: %d/100",
                    $total, $high, $medium, $low, $score
                );
            }

            return {
                issues  => \@issues,
                summary => $summary,
                score   => $score,
            };
        },
    );
}

1;
