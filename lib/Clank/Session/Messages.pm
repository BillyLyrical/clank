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

1;
