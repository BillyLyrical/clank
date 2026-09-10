# CLANK-WIT: name=SkillComply
# CLANK-WIT: version=1.0.0
# CLANK-WIT: about=Meta-quality: measure whether wits are actually selected by RATS when they should be
# CLANK-WIT: usage=Input: { wit?: string, deck?: string, prompts?: string[] } Output: { compliance: [{ wit, expected, actual, rate }], gaps: [...] }
# CLANK-WIT: hint=compliance, skill comply, quality measurement, RATS, tool selection, wit coverage
# CLANK-WIT: author=Clank
# CLANK-WIT: license=Artistic-2.0
#
# ECC skill-comply pattern adapted for Clank. Scans wit metadata, generates
# test prompts, scores them against RATS-like keyword matching, reports
# compliance rates. No LLM calls — purely deterministic.
package Clank::Wits::Build::SkillComply;
use strict;
use warnings;
use File::Find;
use File::Basename;
use Exporter 'import';

our @EXPORT_OK = qw(parse_wit_metadata scan_wits score_prompt);

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'compliance_check',
        description => 'Measure whether wits are selected by RATS when they should be. Scans wit metadata, generates test prompts, scores compliance.',
        parameters  => {
            type       => 'object',
            properties => {
                wit    => { type => 'string', description => 'Check a specific wit by name (e.g. "GateGuard")' },
                deck   => { type => 'string', description => 'Check all wits in a deck (e.g. "build")' },
                prompts => { type => 'array', items => { type => 'string' }, description => 'Custom test prompts to score against wits' },
            },
        },
        execute => sub {
            my ($args) = @_;
            return _run_compliance($args);
        },
    );

    $api->register_command('comply',
        description => 'comply [wit|deck] — run wit compliance check',
        handler => sub {
            my ($ctx, $args) = @_;
            my ($target, @rest) = split /\s+/, ($args // '');
            my $result;
            if ($target) {
                $result = _run_compliance({ wit => $target });
                unless ($result->{compliance} && @{$result->{compliance}}) {
                    $result = _run_compliance({ deck => $target });
                }
            }
            else {
                $result = _run_compliance({});
            }
            return _format_report($result);
        },
    );
}

# === METADATA PARSING ===

sub parse_wit_metadata {
    my ($file) = @_;
    open my $fh, '<', $file or return undef;
    my %meta;
    while (<$fh>) {
        chomp;
        if (/^# CLANK-WIT:\s*(\w+)=(.*)/) {
            $meta{lc $1} = $2;
        }
        last if /^\w/ && !/^#/;  # stop at first non-comment code line
    }
    close $fh;
    return \%meta if %meta;
    return undef;
}

sub scan_wits {
    my (%args) = @_;
    my $wits_dir = $args{dir} // 'wits';
    my @wits;

    find({
        wanted => sub {
            return unless /\.pm$/;
            my $meta = parse_wit_metadata($File::Find::name);
            return unless $meta && $meta->{name};

            my $rel = $File::Find::name;
            $rel =~ s{^.*wits/}{};
            my ($deck) = split m{/}, $rel;

            push @wits, {
                file    => $File::Find::name,
                deck    => $deck,
                name    => $meta->{name},
                about   => $meta->{about} // '',
                usage   => $meta->{usage} // '',
                hint    => $meta->{hint} // '',
                version => $meta->{version} // '0.0.0',
            };
        },
        no_chdir => 1,
    }, $wits_dir);

    return [sort { $a->{deck} cmp $b->{deck} || $a->{name} cmp $b->{name} } @wits];
}

# === RATS-LIKE SCORING ===

sub score_prompt {
    my ($prompt, $wits) = @_;
    my @words = split /\W+/, lc($prompt);
    @words = grep { length($_) > 2 } @words;
    return [] unless @words;

    my @scored;
    for my $wit (@$wits) {
        my $hint_text = join(' ', $wit->{hint}, $wit->{about}, $wit->{name});
        my $score = 0;
        for my $w (@words) {
            $score += 0.3 if $hint_text =~ /\Q$w\E/i;
        }
        next unless $score > 0;
        push @scored, { wit => $wit, score => $score };
    }

    return [sort { $b->{score} <=> $a->{score} } @scored];
}

# === TEST PROMPT GENERATION ===

sub _generate_prompts_for_wit {
    my ($wit) = @_;
    my @prompts;
    my @hint_words = split /,\s*/, $wit->{hint};

    # Direct hint match prompts
    for my $word (@hint_words) {
        $word =~ s/^\s+|\s+$//g;
        next unless length($word) > 2;
        push @prompts, "How do I $word?";
        push @prompts, "Help me with $word";
    }

    # About-based prompts
    if ($wit->{about} =~ /(\w[\w\s]+?)(?:\s*[-—]|$)/) {
        my $topic = $1;
        $topic =~ s/^\s+|\s+$//g;
        push @prompts, "I need to $topic";
    }

    # Tool name prompts (from usage field)
    if ($wit->{usage} =~ /Input:\s*\{[^}]*\}/) {
        my $usage = $&;
        if ($usage =~ /(\w+):\s*"([^"]+)"/) {
            push @prompts, "Run $2";
        }
    }

    return @prompts;
}

# === COMPLIANCE RUNNER ===

sub _run_compliance {
    my ($args) = @_;
    my $wits = scan_wits(dir => 'wits');

    my @target_wits;
    if ($args->{wit}) {
        my $name = lc($args->{wit});
        @target_wits = grep { lc($_->{name}) eq $name || $_->{name} eq $args->{wit} } @$wits;
        return { compliance => [], gaps => ["Wit '$args->{wit}' not found"], scanned => scalar @$wits }
            unless @target_wits;
    }
    elsif ($args->{deck}) {
        @target_wits = grep { $_->{deck} eq $args->{deck} } @$wits;
        return { compliance => [], gaps => ["No wits in deck '$args->{deck}'"], scanned => scalar @$wits }
            unless @target_wits;
    }
    else {
        @target_wits = @$wits;
    }

    my @compliance;
    my @gaps;

    for my $wit (@target_wits) {
        my @prompts;
        if ($args->{prompts} && @{$args->{prompts}}) {
            @prompts = @{$args->{prompts}};
        }
        else {
            @prompts = _generate_prompts_for_wit($wit);
        }

        next unless @prompts;

        my $hits = 0;
        my @misses;

        for my $prompt (@prompts) {
            my $scored = score_prompt($prompt, $wits);
            my $top = $scored->[0];
            if ($top && $top->{wit}{name} eq $wit->{name}) {
                $hits++;
            }
            else {
                my $top_name = $top ? $top->{wit}{name} : '(none)';
                push @misses, { prompt => $prompt, top_wit => $top_name };
            }
        }

        my $rate = @prompts ? $hits / @prompts : 0;
        push @compliance, {
            wit      => $wit->{name},
            deck     => $wit->{deck},
            expected => scalar @prompts,
            actual   => $hits,
            rate     => $rate,
            misses   => \@misses,
        };

        if ($rate < 0.5 && @prompts >= 2) {
            push @gaps, sprintf("%s/%s: %.0f%% compliance (%d/%d) — hint may need strengthening",
                $wit->{deck}, $wit->{name}, $rate * 100, $hits, scalar @prompts);
        }
    }

    return {
        compliance => [sort { $a->{rate} <=> $b->{rate} } @compliance],
        gaps       => \@gaps,
        scanned    => scalar @$wits,
    };
}

# === REPORT FORMATTING ===

sub _format_report {
    my ($result) = @_;
    my @lines;

    push @lines, "=== Wit Compliance Report ===";
    push @lines, "Scanned: $result->{scanned} wits";
    push @lines, "";

    if (@{$result->{gaps}}) {
        push @lines, "--- Gaps (hint strengthening needed) ---";
        for my $g (@{$result->{gaps}}) {
            push @lines, "  $g";
        }
        push @lines, "";
    }

    push @lines, "--- Compliance Rates ---";
    for my $c (@{$result->{compliance}}) {
        my $bar = '=' x int($c->{rate} * 20);
        push @lines, sprintf("  %-20s %s %.0f%% (%d/%d)",
            "$c->{deck}/$c->{wit}", $bar, $c->{rate} * 100, $c->{actual}, $c->{expected});

        if (@{$c->{misses}}) {
            for my $m (@{$c->{misses}}) {
                push @lines, sprintf("    miss: \"%s\" → top: %s", $m->{prompt}, $m->{top_wit});
            }
        }
    }

    return join("\n", @lines);
}

1;
