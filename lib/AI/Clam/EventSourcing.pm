# AI::Clam::EventSourcing — immutable state-change log for "why did it do that?"
# debugging and replay.
#
# Every state change (fact asserted, belief superseded, rule crystallized)
# is recorded as an immutable event. The log can be replayed to rebuild
# current state or trace the history of any aggregate.
#
# Integrates with WorldModel and Rules by wrapping their mutation methods.
# The event log is append-only — no updates, no deletes.
package AI::Clam::EventSourcing;
use strict;
use warnings;
use AI::Clam::Util qw(uuid4 jencode jdecode);

sub new {
    my ($class, %args) = @_;
    my $store = $args{store} // die "AI::Clam::EventSourcing requires store\n";
    my $self = bless {
        store    => $store,
        bus      => $args{bus},
        _snapshots => {},   # aggregate_type => { id => state }
    }, $class;
    $self->_init_schema;
    return $self;
}

sub _dbh { $_[0]->{store}->dbh }

sub _init_schema {
    my ($self) = @_;
    $self->_dbh->do(qq{
CREATE TABLE IF NOT EXISTS event_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  event_type TEXT NOT NULL,
  aggregate_type TEXT NOT NULL,
  aggregate_id TEXT NOT NULL,
  payload TEXT NOT NULL,
  metadata TEXT,
  caused_by TEXT,
  created_at INTEGER NOT NULL
)});
    $self->_dbh->do(qq{
CREATE INDEX IF NOT EXISTS idx_event_log_agg ON event_log(aggregate_type, aggregate_id, created_at)});
    $self->_dbh->do(qq{
CREATE INDEX IF NOT EXISTS idx_event_log_type ON event_log(event_type, created_at)});
    $self->_dbh->do(qq{
CREATE INDEX IF NOT EXISTS idx_event_log_caused ON event_log(caused_by)});
}

# === EMIT ===

# Record a state change. Append-only, immutable.
#   event_type:       created, updated, deleted, superseded, crystallized, asserted, retracted
#   aggregate_type:   entity, relation, fact, belief, rule
#   aggregate_id:     the id of the thing that changed
#   payload:          hashref of what changed (before/after for updates)
#   metadata:         optional hashref (who triggered, why)
#   caused_by:        optional event_id that caused this event (causal chain)
sub emit {
    my ($self, %args) = @_;
    my $event_type     = $args{event_type}     // die "emit requires event_type\n";
    my $aggregate_type = $args{aggregate_type} // die "emit requires aggregate_type\n";
    my $aggregate_id   = $args{aggregate_id}   // die "emit requires aggregate_id\n";
    my $payload        = ref $args{payload} eq 'HASH' ? $args{payload} : ($args{payload} // {});
    my $metadata       = $args{metadata}  // {};
    my $caused_by      = $args{caused_by};

    my $now = int(time() * 1000);
    $self->_dbh->prepare(
        'INSERT INTO event_log (event_type,aggregate_type,aggregate_id,payload,metadata,caused_by,created_at) VALUES (?,?,?,?,?,?,?)'
    )->execute($event_type, $aggregate_type, $aggregate_id,
               jencode($payload), jencode($metadata), $caused_by, $now);

    my $event_id = $self->_dbh->last_insert_id(undef, undef, 'event_log', 'id');

    $self->_publish('event.emitted', {
        event_id       => $event_id,
        event_type     => $event_type,
        aggregate_type => $aggregate_type,
        aggregate_id   => $aggregate_id,
    });

    return $event_id;
}

# === QUERY ===

# Get all events for an aggregate (its full history).
sub history {
    my ($self, $aggregate_type, $aggregate_id, %args) = @_;
    my $limit = $args{limit} // 1000;
    my $since = $args{since};   # event_id — get events after this one
    my $until = $args{until};   # event_id — get events up to and including this one

    my ($sql, @bind) = ('SELECT * FROM event_log WHERE aggregate_type=? AND aggregate_id=?',
                         $aggregate_type, $aggregate_id);

    if (defined $since) {
        $sql .= ' AND id > ?';
        push @bind, $since;
    }
    if (defined $until) {
        $sql .= ' AND id <= ?';
        push @bind, $until;
    }
    $sql .= ' ORDER BY created_at ASC, id ASC LIMIT ?';
    push @bind, $limit;

    my $rows = $self->_dbh->selectall_arrayref($sql, { Slice => {} }, @bind);
    for my $row (@$rows) {
        $row->{payload}  = jdecode($row->{payload});
        $row->{metadata} = jdecode($row->{metadata});
    }
    return $rows;
}

# Get events by type (e.g., all crystallizations).
sub events_by_type {
    my ($self, $event_type, %args) = @_;
    my $limit = $args{limit} // 100;
    my $since = $args{since};

    my ($sql, @bind) = ('SELECT * FROM event_log WHERE event_type=?', $event_type);
    if (defined $since) {
        $sql .= ' AND created_at >= ?';
        push @bind, $since;
    }
    $sql .= ' ORDER BY created_at DESC LIMIT ?';
    push @bind, $limit;

    my $rows = $self->_dbh->selectall_arrayref($sql, { Slice => {} }, @bind);
    for my $row (@$rows) {
        $row->{payload}  = jdecode($row->{payload});
        $row->{metadata} = jdecode($row->{metadata});
    }
    return $rows;
}

# Trace causal chain: what caused this event?
sub trace_causes {
    my ($self, $event_id, %args) = @_;
    my $max_depth = $args{max_depth} // 20;

    my @chain;
    my $current_id = $event_id;
    my %seen;

    while ($current_id && $max_depth-- > 0 && !$seen{$current_id}++) {
        my $row = $self->_dbh->selectrow_hashref(
            'SELECT * FROM event_log WHERE id=?', undef, $current_id);
        last unless $row;
        $row->{payload}  = jdecode($row->{payload});
        $row->{metadata} = jdecode($row->{metadata});
        unshift @chain, $row;
        $current_id = $row->{caused_by};
    }

    return \@chain;
}

# What did this event cause? (downstream effects)
sub trace_effects {
    my ($self, $event_id, %args) = @_;
    my $limit = $args{limit} // 50;

    my $rows = $self->_dbh->selectall_arrayref(
        'SELECT * FROM event_log WHERE caused_by=? ORDER BY created_at ASC LIMIT ?',
        { Slice => {} }, $event_id, $limit);
    for my $row (@$rows) {
        $row->{payload}  = jdecode($row->{payload});
        $row->{metadata} = jdecode($row->{metadata});
    }
    return $rows;
}

# === REPLAY ===

# Replay all events and rebuild current state.
# Returns { aggregate_type => { id => last_payload } }
sub replay {
    my ($self, %args) = @_;
    my $since = $args{since};    # event_id
    my $until = $args{until};    # event_id
    my $aggregate_type = $args{aggregate_type};  # optional filter

    my ($sql, @bind) = ('SELECT * FROM event_log');
    my @where;
    if ($aggregate_type) {
        push @where, 'aggregate_type = ?';
        push @bind, $aggregate_type;
    }
    if (defined $since) {
        push @where, 'id > ?';
        push @bind, $since;
    }
    if (defined $until) {
        push @where, 'id <= ?';
        push @bind, $until;
    }
    $sql .= ' WHERE ' . join(' AND ', @where) if @where;
    $sql .= ' ORDER BY created_at ASC, id ASC';

    my $rows = $self->_dbh->selectall_arrayref($sql, { Slice => {} }, @bind);

    my %state;
    for my $row (@$rows) {
        my $payload = jdecode($row->{payload});
        my $at = $row->{aggregate_type};
        my $aid = $row->{aggregate_id};
        my $et = $row->{event_type};

        if ($et eq 'deleted' || $et eq 'retracted') {
            delete $state{$at}{$aid};
        } else {
            $state{$at}{$aid} = $payload;
        }
    }

    return \%state;
}

# Snapshot: current state of an aggregate.
sub snapshot {
    my ($self, $aggregate_type, $aggregate_id) = @_;
    my $events = $self->history($aggregate_type, $aggregate_id);
    return undef unless @$events;

    my $state;
    for my $ev (@$events) {
        if ($ev->{event_type} eq 'deleted' || $ev->{event_type} eq 'retracted') {
            $state = undef;
        } else {
            $state = $ev->{payload};
        }
    }
    return $state;
}

# === STATS ===

sub stats {
    my ($self) = @_;
    my $dbh = $self->_dbh;
    my $total = $dbh->selectrow_array('SELECT COUNT(*) FROM event_log');
    my $types = $dbh->selectall_arrayref(
        'SELECT event_type, COUNT(*) as cnt FROM event_log GROUP BY event_type ORDER BY cnt DESC',
        { Slice => {} });
    my $aggregates = $dbh->selectall_arrayref(
        'SELECT aggregate_type, COUNT(DISTINCT aggregate_id) as cnt FROM event_log GROUP BY aggregate_type ORDER BY cnt DESC',
        { Slice => {} });
    return {
        total_events => $total,
        by_type      => $types,
        aggregates   => $aggregates,
    };
}

sub _publish {
    my ($self, $topic, $payload) = @_;
    return unless $self->{bus};
    eval { $self->{bus}->publish($topic, $payload, sender => 'eventsourcing') };
}

1;

__END__

=encoding utf-8

=head1 NAME

AI::Clam::EventSourcing — immutable state-change log for "why did it do that?"
debugging and replay. Every state change is recorded as an append-only event.

=head1 SYNOPSIS

  use AI::Clam::EventSourcing;

  my $es = AI::Clam::EventSourcing->new(store => $store);

  # Record a state change:
  my $id = $es->emit(
      event_type     => 'asserted',
      aggregate_type => 'fact',
      aggregate_id   => 'f1',
      payload        => { predicate => 'capital_of', value => 'Paris' },
      metadata       => { source => 'llm' },
      caused_by      => $previous_event_id,   # causal chain
  );

  # Trace history:
  my $history = $es->history('fact', 'f1');        # all events for this fact
  my $cryst   = $es->events_by_type('crystallized');

  # Causal debugging:
  my $causes  = $es->trace_causes($event_id);     # what led to this?
  my $effects = $es->trace_effects($event_id);    # what did this trigger?

  # Replay:
  my $state = $es->replay;                         # rebuild everything
  my $snap  = $es->snapshot('entity', 'e1');       # current state of one aggregate

=head1 DESCRIPTION

AI::Clam::EventSourcing is an append-only event log. Every state change —
fact asserted, belief superseded, rule crystallized — is recorded as an
immutable event with a causal chain pointer.

The event log enables:

=over 4

=item Replay — rebuild current state by replaying all events.

=item Debugging — trace back from any state change to its root cause.

=item Audit — see the full history of any aggregate (entity, fact, rule).

=item Time travel — replay to any point in time (via event_id bounds).

=back

Events are keyed by aggregate (type + id). Each event has:
C<event_type>, C<aggregate_type>, C<aggregate_id>, C<payload>,
C<metadata>, C<caused_by> (causal chain), C<created_at>.

Standard event types: C<created>, C<updated>, C<deleted>, C<asserted>,
C<retracted>, C<superseded>, C<crystallized>.

=head1 METHODS

=head2 new(%args)

Constructor. Required: C<store>. Optional: C<bus> (for event.emitted events).

=head2 emit(%args)

Record a state change. Required: C<event_type>, C<aggregate_type>,
C<aggregate_id>. Optional: C<payload>, C<metadata>, C<caused_by>.
Returns the auto-increment event id.

=head2 history($type, $id, %args)

All events for an aggregate. Options: C<since> (event_id), C<until>
(event_id), C<limit> (default 1000).

=head2 events_by_type($event_type, %args)

All events of a given type. Options: C<since> (timestamp), C<limit>.

=head2 trace_causes($event_id, %args)

Walk C<caused_by> chain backward. Returns arrayref of events from root
cause to this event. Options: C<max_depth> (default 20).

=head2 trace_effects($event_id, %args)

Find all events that were caused by this one. Options: C<limit>.

=head2 replay(%args)

Replay all events and rebuild current state. Returns
C<{ aggregate_type => { id => payload } }>. Options: C<since>,
C<until>, C<aggregate_type>.

=head2 snapshot($type, $id)

Current state of one aggregate (replays its history).

=head2 stats

Returns C<{ total_events, by_type, aggregates }>.

=head1 SEE ALSO

L<AI::Clam::WorldModel>, L<AI::Clam::Rules::Engine>, L<AI::Clam::Tracer>

=cut
