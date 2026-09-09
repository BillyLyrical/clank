# Clank::ToolSelector — Retrieval-Augmented Tool Selection (RATS).
#
# Instead of dumping all tools into the LLM prompt, score them by relevance
# to the current task and return only the most relevant ones.
#
# Scoring: keyword overlap between tool hints/descriptions and the prompt,
# plus context signals (recent use, wit affinity, file type, error recovery).
package Clank::ToolSelector;
use strict;
use warnings;

# Select the most relevant tools for a given prompt.
# Returns arrayref of tool objects, sorted by relevance descending.
#
# Optional context hash for secondary signals:
#   recent_tools => ['git_status', ...]   tools used in recent turns (boost)
#   loaded_wits  => ['git', 'db']         currently loaded deck names (boost)
#   file_types   => ['pm', 'pl']          file types being worked on (boost)
#   error_msg    => 'Can\'t locate ...'   last error message (boost matching tools)
sub select {
    my ($class, %args) = @_;
    my $tools   = $args{tools}   // [];    # arrayref of Clank::Tool objects
    my $prompt  = $args{prompt}  // '';
    my $max     = $args{max}     // 30;    # max tools to return
    my $min_score = $args{min_score} // 0;
    my $context = $args{context} // {};    # secondary signals

    return $tools if scalar @$tools <= $max;

    my @prompt_words = _tokenize($prompt);

    # Pre-compute context sets for fast lookup.
    my %recent = map { $_ => 1 } @{ $context->{recent_tools} // [] };
    my %wits   = map { $_ => 1 } @{ $context->{loaded_wits}  // [] };
    my %ftypes = map { $_ => 1 } @{ $context->{file_types}   // [] };
    my @err_words = _tokenize($context->{error_msg} // '');

    my @scored;
    for my $tool (@$tools) {
        my $text = join(' ', $tool->{description} // '', $tool->{name} // '');
        $text .= ' ' . ($tool->{hint} // '') if $tool->{hint};

        my @tool_words = _tokenize($text);
        my $score = @prompt_words ? _score(\@prompt_words, \@tool_words) : 0;

        # Context boosts (additive, small enough not to overwhelm base score).
        # Recent tools: boost tools used in the last few turns.
        $score += 0.3 if $recent{ $tool->{name} };

        # Wit affinity: boost tools from currently loaded decks.
        # Match tool name prefix against deck names (git_status -> git).
        if (%wits) {
            my $tname = $tool->{name} // '';
            for my $deck (keys %wits) {
                $score += 0.2 if $tname =~ /^\Q$deck\E/;
            }
        }

        # File type: boost tools whose hint/description mentions the file type.
        if (%ftypes) {
            my $combined = join(' ', $tool->{hint} // '', $tool->{description} // '');
            for my $ft (keys %ftypes) {
                $score += 0.15 if $combined =~ /\Q$ft\E/i;
            }
        }

        # Error recovery: boost tools whose hint/description matches error words.
        if (@err_words) {
            my @tw = _tokenize(join(' ', $tool->{hint} // '', $tool->{description} // ''));
            my $err_matches = _count_overlap(\@err_words, \@tw);
            $score += 0.25 * $err_matches if $err_matches;
        }

        next if $score < $min_score;
        push @scored, { tool => $tool, score => $score };
    }

    # Sort by score descending, take top N.
    @scored = sort { $b->{score} <=> $a->{score} } @scored;
    @scored = @scored[0 .. ($max - 1)] if @scored > $max;

    # If nothing scored, return first N tools (deterministic fallback).
    return [ @{$tools}[0 .. ($max - 1)] ] unless @scored;

    return [ map { $_->{tool} } @scored ];
}

# Tokenize text into lowercase words, filter stop words.
sub _tokenize {
    my ($text) = @_;
    return () unless defined $text && length $text;
    my @words = split /\W+/, lc($text);
    # Filter very short words and common stop words.
    my %stop = map { $_ => 1 } qw(a an the is are was were be been being
        have has had do does did will would could should may might can shall
        to of in for on with at by from as into through during before after
        above below between out off over under again further then once here
        there when where why how all each every both few more most other some
        such no nor not only own same so than too very just don now);
    return grep { length($_) > 1 && !$stop{$_} } @words;
}

# Count overlap between two word lists.
sub _count_overlap {
    my ($a, $b) = @_;
    my %b_freq;
    $b_freq{$_}++ for @$b;
    my $n = 0;
    $n++ for grep { $b_freq{$_} } @$a;
    return $n;
}

# Score overlap between prompt words and tool words.
# Simple TF-based scoring: count matching words, weighted by uniqueness.
sub _score {
    my ($prompt_words, $tool_words) = @_;
    return 0 unless @$prompt_words && @$tool_words;

    my %tool_freq;
    $tool_freq{$_}++ for @$tool_words;
    my $tool_total = scalar @$tool_words;

    my $matches = 0;
    for my $pw (@$prompt_words) {
        if ($tool_freq{$pw}) {
            # Bonus for rare words (appear in fewer tool descriptions).
            $matches += 1;
        }
    }

    # Normalize by prompt length (reward concentration of matches).
    return $matches / scalar @$prompt_words;
}

1;
