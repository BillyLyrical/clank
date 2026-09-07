# Pi-semantics compaction: when est_tokens(context) > context_window - reserve,
# summarize the older span into a structured summary and insert it as a
# 'compaction' message. Context after compaction = [summary] + kept messages.
package AI::Clam::Session::Compaction;
use strict;
use warnings;
use AI::Clam::Session::Messages ();
use AI::Clam::Util qw(jencode);

sub new {
    my ($class, %o) = @_;
    return bless {
        context_window => $o{context_window} // 128_000,
        reserve_tokens => $o{reserve_tokens} // 16_384,
        keep_recent    => $o{keep_recent}    // 20_000,
    }, $class;
}

sub should_compact {
    my ($self, $est) = @_;
    return $est > $self->{context_window} - $self->{reserve_tokens} ? 1 : 0;
}

# Returns the new compaction message id, or undef (nothing to compact / cancelled).
sub compact {
    my ($self, %o) = @_;
    my $store      = $o{store}      or die "compact: store required";
    my $sid        = $o{session_id} or die "compact: session_id required";
    my $provider   = $o{provider}   or die "compact: provider required";
    my $bus        = $o{bus};
    my $instructions = $o{instructions};

    my $all = $store->message_path($sid);          # full chain, root-first
    return undef unless @$all >= 4;

    # Index of the most recent compaction entry (iterative summarization).
    my ($ci, $n) = (-1, scalar @$all);
    for my $i (0 .. $n - 1) { $ci = $i if (($all->[$i]{role} // '') eq 'compaction') }

    # Walk back from newest until we hold keep_recent tokens.
    my ($acc, $cut) = (0, $n);
    for my $i (reverse($ci + 1 .. $n - 1)) {
        $acc += AI::Clam::Session::Messages::est_tokens([ AI::Clam::Session::Messages::to_provider($all->[$i]) ]);
        $cut = $i;
        last if $acc >= $self->{keep_recent};
    }
    return undef if $cut <= $ci + 1;               # nothing old enough to summarize

    my @older = @{$all}[$ci + 1 .. $cut - 1];
    my $prev_summary = ($ci >= 0 && ref $all->[$ci]{content} eq 'HASH') ? ($all->[$ci]{content}{summary} // '') : '';

    # session_before_compact hook: wits may cancel or add instructions.
    if ($bus) {
        my $pub = $bus->publish('session_before_compact',
            { session_id => $sid, messages_to_summarize => scalar @older });
        for my $r (@{ $pub->{results} }) {
            next unless ref $r eq 'HASH';
            return undef if $r->{cancel};
            $instructions = ($instructions ? "$instructions\n" : '') . $r->{instructions}
                if defined $r->{instructions};
        }
    }

    my $sys = "You are summarizing a coding-agent conversation for context compaction. "
            . "Produce a structured summary with these sections: "
            . "## Goal\n## Decisions\n## Files touched\n## Open threads\n"
            . ($instructions ? "Additional instructions: $instructions\n" : '')
            . "Be precise and terse; the summary replaces the summarized messages.";
    my $user = ($prev_summary ? "Previous summary (update it):\n$prev_summary\n\n" : '')
             . "Conversation to summarize:\n\n" . _transcript(\@older);

    my $resp = eval {
        $provider->post_json('/chat/completions', {
            model    => $provider->{model},
            messages => [ { role => 'system', content => $sys }, { role => 'user', content => $user } ],
        });
    };
    if ($@ || !$resp) {
        my $err = "$@";
        $bus->publish('session_compact_failed', { session_id => $sid, error => $err }) if $bus;
        return undef;
    }
    my $summary = $resp->{choices}[0]{message}{content} // '';

    # Appends under the current leaf and moves the conversation position to
    # the new compaction entry (subsequent messages hang off it).
    my $id = AI::Clam::Session::Messages::add(
        $store, $sid,
        role    => 'compaction',
        content => {
            summary          => $summary,
            first_kept_id    => $all->[$cut]{id},
            summarized_count => scalar @older,
        },
    );
    $bus->publish('session_compact',
        { session_id => $sid, compaction_id => $id, kept_messages => $n - $cut }) if $bus;
    return $id;
}

sub _transcript {
    my ($msgs) = @_;
    my @lines;
    for my $m (@$msgs) {
        my ($c, $role) = ($m->{content}, $m->{role});
        if (($role // '') eq 'assistant' && ref $c eq 'HASH') {
            push @lines, "ASSISTANT: " . ($c->{text} // '');
            for my $tc (@{ $c->{tool_calls} // [] }) {
                push @lines, "  TOOL_CALL " . $tc->{name} . "(" . jencode($tc->{arguments} // {}) . ")";
            }
        } elsif (($role // '') eq 'toolResult' && ref $c eq 'HASH') {
            push @lines, "TOOL_RESULT: " . substr($c->{output} // '', 0, 2000);
        } else {
            push @lines, uc($role // '?') . ": " . (ref $c ? jencode($c) : "$c");
        }
    }
    return join("\n", @lines);
}

1;
