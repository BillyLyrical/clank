# Message tree ops + provider-format mapping over Clank::Store.
package Clank::Session::Messages;
use strict;
use warnings;
use Clank::Util qw(jencode);

# Append a message under the current leaf (or explicit parent). Returns id.
# A normal append moves the session's conversation position to the new
# message; an explicit-parent branch does not (the main line keeps its head —
# use $store->set_leaf to switch to a branch deliberately).
sub add {
    my ($store, $sid, %a) = @_;
    my $branching = defined $a{parent_id};
    # NOTE: force scalar context — fetchrow_array returns a LIST in list context,
    # which would silently eat the hash key below.
    my $parent = $branching ? $a{parent_id} : scalar($store->leaf_message($sid));
    my $id = $store->append_message(
        session_id => $sid,
        parent_id  => $parent,
        role       => $a{role},
        content    => $a{content},
    );
    $store->set_leaf($sid, $id) unless $branching;
    return $id;
}

# Root-first rows (content decoded). Respects the most recent compaction entry:
# everything before it is dropped; the entry itself maps to a summary message.
sub chain {
    my ($store, $sid, $leaf) = @_;
    my $all = $store->message_path($sid, $leaf);
    for my $i (reverse(0 .. $#$all)) {
        if (($all->[$i]{role} // '') eq 'compaction') {
            return [ $all->[$i], @{ $all }[ $i + 1 .. $#$all ] ];
        }
    }
    return $all;
}
sub head { $_[0]->leaf_message($_[1]) }

# Map one stored row -> OpenAI provider message.
sub to_provider {
    my ($m) = @_;
    my $c = $m->{content};
    if (($m->{role} // '') eq 'user') {
        my $text;
        if (ref $c eq 'ARRAY') {
            $text = join('', map { $_->{text} // '' } grep { ($_->{type} // 'text') eq 'text' } @$c);
        } else { $text = defined $c ? "$c" : ''; }
        return { role => 'user', content => $text };
    }
    if (($m->{role} // '') eq 'assistant') {
        my %p = ( role => 'assistant', content => ($c && ref $c eq 'HASH' && defined $c->{text}) ? $c->{text} : '' );
        my @tcs = ref $c eq 'HASH' ? @{ $c->{tool_calls} // [] } : ();
        if (@tcs) {
            $p{tool_calls} = [ map {
                { id => $_->{id}, type => 'function',
                  function => { name => $_->{name}, arguments => jencode($_->{arguments} // {}) } };
            } @tcs ];
        }
        return \%p;
    }
    if (($m->{role} // '') eq 'toolResult') {
        my $out = (ref $c eq 'HASH' && defined $c->{output}) ? $c->{output} : '';
        $out .= "\n[isError]" if ref $c eq 'HASH' && $c->{isError};
        return { role => 'tool', tool_call_id => (ref $c eq 'HASH') ? ($c->{tool_call_id} // '') : '', content => $out };
    }
    if (($m->{role} // '') eq 'compaction' && ref $c eq 'HASH') {
        return { role => 'user', content => "[conversation summary]\n" . ($c->{summary} // '') };
    }
    # custom entries: surface as a user message with a marker.
    my $body = ref $c ? jencode($c) : "$c";
    return { role => 'user', content => "[note]\n$body" };
}

sub to_provider_list { my ($chain) = @_; return [ map { to_provider($_) } @$chain ] }

# Rough token estimate over provider messages (~4 chars/token).
sub est_tokens {
    my ($msgs) = @_;
    my $n = 0;
    for my $m (@$msgs) {
        my $c = $m->{content};
        $n += length(ref $c ? jencode($c) : "$c");
        if (ref $m->{tool_calls} eq 'ARRAY') {
            $n += length(jencode($m->{tool_calls}));
        }
    }
    return int($n / 4);
}

# Context-aware pruning: remove old turns that are not referenced by recent
# messages. Keeps compaction summaries, recent turns, and any turn that is
# referenced by a tool call or explicit reference.
#
# Strategy:
# - Keep all compaction entries (they're already compressed)
# - Keep the last $keep_recent turns (default 20)
# - For older turns: keep if referenced by a tool_call_id in kept messages
# - Drop unreferenced old turns
sub prune_context {
    my ($chain, %args) = @_;
    my $keep_recent = $args{keep_recent} // 20;
    return $chain unless @$chain > $keep_recent + 4;

    # Identify tool_call_ids referenced by recent messages.
    my @recent = @$chain[ -$keep_recent .. -1 ];
    my %referenced_ids;
    for my $m (@recent) {
        # toolResult messages reference a tool_call_id
        if (($m->{role} // '') eq 'toolResult' && ref $m->{content} eq 'HASH') {
            $referenced_ids{ $m->{content}{tool_call_id} } = 1 if $m->{content}{tool_call_id};
        }
        # assistant messages with tool_calls define the ids
        if (($m->{role} // '') eq 'assistant' && ref $m->{content} eq 'HASH') {
            for my $tc (@{ $m->{content}{tool_calls} // [] }) {
                $referenced_ids{ $tc->{id} } = 1 if $tc->{id};
            }
        }
    }

    # Build pruned chain: keep compaction entries, recent turns, and referenced old turns.
    my @pruned;
    for my $m (@$chain) {
        # Always keep compaction entries.
        if (($m->{role} // '') eq 'compaction') {
            push @pruned, $m;
            next;
        }

        # Check if this is in the recent window.
        my $in_recent = 0;
        for my $r (@recent) {
            if ($m->{id} eq $r->{id}) { $in_recent = 1; last }
        }
        if ($in_recent) {
            push @pruned, $m;
            next;
        }

        # Old turn: keep if it's a toolResult referenced by recent messages.
        if (($m->{role} // '') eq 'toolResult' && ref $m->{content} eq 'HASH') {
            my $tcid = $m->{content}{tool_call_id} // '';
            if ($referenced_ids{$tcid}) {
                push @pruned, $m;
                next;
            }
        }

        # Drop all other old turns (user, assistant).
    }

    return @pruned > 4 ? \@pruned : $chain;
}

1;
