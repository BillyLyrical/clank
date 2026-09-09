# Clank::Mesh — cross-session communication via the bus.
#
# Sessions communicate through bus topics. Each session subscribes to
# its own topic (session.{id}.message) and can publish to any other
# session's topic. The bus is the shared medium; the SQLite store
# journals all events for persistence and replay.
#
# In daemon mode, all sessions share the same in-process bus — messaging
# is immediate. In multi-process mode, sessions share the same SQLite
# database — messages are durable but require polling.
package Clank::Mesh;
use strict;
use warnings;
use Clank::Util qw(now_ms);

sub new {
    my ($class, %args) = @_;
    return bless {
        bus       => $args{bus},
        store     => $args{store},
        session_id => $args{session_id},
        metrics   => $args{metrics},
        _sub_id   => undef,               # our subscription id
        _handlers => [],                  # message handlers
    }, $class;
}

sub register {
    my ($self, $api) = @_;
    $self->{bus}   //= $api->bus;
    $self->{store} //= $api->store;
    return $self;
}

# --- SUBSCRIBE ---

# Subscribe to messages addressed to our session.
# Handler receives: { from => session_id, payload => ..., topic => ... }
sub subscribe {
    my ($self, %opts) = @_;
    my $bus = $self->{bus} or return;
    my $sid = $self->{session_id} or return;

    my $topic = "session.$sid.message";

    $self->{_sub_id} = $bus->subscribe($topic, sub {
        my ($ev) = @_;
        my $payload = $ev->{payload} // {};
        my $from = $payload->{_from_session} // $ev->{sender} // 'unknown';

        my $msg = {
            from    => $from,
            payload => $payload,
            topic   => $ev->{topic},
            id      => $ev->{id},
            time    => $ev->{created_at} // now_ms(),
        };

        # Invoke registered handlers.
        for my $h (@{$self->{_handlers}}) {
            eval { $h->($msg) };
            warn "[mesh] handler error: $@" if $@;
        }

        $self->{metrics}->inc('mesh.received') if $self->{metrics};
        return undef;   # must return undef — bus gathers defined results
    }, name => "mesh:$sid");

    return $self->{_sub_id};
}

# Unsubscribe from our session topic.
sub unsubscribe {
    my ($self) = @_;
    my $bus = $self->{bus} or return;
    if (defined $self->{_sub_id}) {
        $bus->unsubscribe($self->{_sub_id});
        $self->{_sub_id} = undef;
    }
}

# Register a handler for incoming messages.
sub on_message {
    my ($self, $code) = @_;
    push @{$self->{_handlers}}, $code if ref $code eq 'CODE';
}

# --- PUBLISH ---

# Send a message to another session.
sub send {
    my ($self, $to_session, $payload) = @_;
    my $bus = $self->{bus} or return;
    my $sid = $self->{session_id} or return;

    my $topic = "session.$to_session.message";
    my $envelope = {
        %$payload,
        _from_session => $sid,
        _timestamp    => now_ms(),
    };

    my $pub = $bus->publish($topic, $envelope, sender => "mesh:$sid");
    $self->{metrics}->inc('mesh.sent') if $self->{metrics};

    return {
        ok       => 1,
        event_id => $pub->{id},
        topic    => $topic,
    };
}

# Broadcast a message to all sessions (publish to mesh.broadcast).
sub broadcast {
    my ($self, $payload) = @_;
    my $bus = $self->{bus} or return;
    my $sid = $self->{session_id} or return;

    my $envelope = {
        %$payload,
        _from_session => $sid,
        _broadcast    => 1,
        _timestamp    => now_ms(),
    };

    my $pub = $bus->publish('mesh.broadcast', $envelope, sender => "mesh:$sid");
    $self->{metrics}->inc('mesh.broadcasts') if $self->{metrics};

    return {
        ok       => 1,
        event_id => $pub->{id},
    };
}

# --- QUERY ---

# Query the event journal for messages between sessions.
# This works across processes — the SQLite store is the shared medium.
sub query_messages {
    my ($self, %opts) = @_;
    my $store = $self->{store} or return [];
    my $from_session = $opts{from};
    my $limit = $opts{limit} // 50;

    # Use SQL LIKE with '%' wildcard (not glob '*') for topic matching.
    my @rows = @{ $store->query_events(
        topic  => 'session.%.message',
        limit  => $limit * 2,
    ) };

    # Filter by sender if specified.
    if (defined $from_session) {
        @rows = grep {
            my $p = ref $_->{payload} eq 'HASH' ? $_->{payload} : {};
            ($p->{_from_session} // '') eq $from_session;
        } @rows;
    }

    # Decode payloads and trim.
    my @messages;
    for my $row (@rows[0 .. ($#rows > $limit - 1 ? $limit - 1 : $#rows)]) {
        my $p = ref $row->{payload} eq 'HASH' ? $row->{payload} : {};
        push @messages, {
            id      => $row->{id},
            topic   => $row->{topic},
            from    => $p->{_from_session} // $row->{sender} // 'unknown',
            payload => $p,
            time    => $row->{created_at},
        };
    }

    return \@messages;
}

1;
