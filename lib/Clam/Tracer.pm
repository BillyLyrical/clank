# Clam::Tracer — event-trace log for pipeline observability.
#
# Records who called what, when, and how long it took. Makes the
# LLM → rules → world model → crystallization pipeline visible.
#
# Two modes:
#   1. Manual — start_span/end_span around code blocks
#   2. Auto — subscribe to bus events and trace them automatically
#
# All spans are persisted in SQLite via Clam::Store for post-hoc query.
package Clam::Tracer;
use strict;
use warnings;
use Clam::Util qw(uuid4 jencode jdecode);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);

sub new {
    my ($class, %args) = @_;
    my $store = $args{store} // die "Clam::Tracer requires store\n";
    my $self = bless {
        store     => $store,
        bus       => $args{bus},
        _spans    => {},   # id => { name, started_at, metadata }
        _active   => [],   # stack of active span ids (nesting)
    }, $class;
    $self->_init_schema;
    $self->_auto_subscribe if $args{auto_subscribe};
    return $self;
}

sub _dbh { $_[0]->{store}->dbh }

sub _init_schema {
    my ($self) = @_;
    $self->_dbh->do(qq{
CREATE TABLE IF NOT EXISTS trace_spans (
  id TEXT PRIMARY KEY,
  parent_id TEXT,
  name TEXT NOT NULL,
  topic TEXT,
  started_at REAL NOT NULL,
  ended_at REAL,
  duration_ms REAL,
  metadata TEXT,
  created_at INTEGER
)});
    $self->_dbh->do(qq{
CREATE INDEX IF NOT EXISTS idx_trace_spans_topic ON trace_spans(topic, started_at)});
}

# === MANUAL TRACING ===

# Start a span. Returns span id. Parent is the current active span (if any).
sub start_span {
    my ($self, $name, %meta) = @_;
    my $id = uuid4();
    my $now = clock_gettime(CLOCK_MONOTONIC);
    my $parent_id = $self->{_active}[-1] // undef;
    my $topic = delete $meta{topic};

    $self->{_spans}{$id} = {
        name       => $name,
        started_at => $now,
        topic      => $topic,
        metadata   => \%meta,
    };

    $self->_dbh->prepare(
        'INSERT INTO trace_spans (id,parent_id,name,topic,started_at,metadata,created_at) VALUES (?,?,?,?,?,?,?)'
    )->execute($id, $parent_id, $name, $topic, $now, jencode(\%meta), int(time() * 1000));

    push @{$self->{_active}}, $id;
    return $id;
}

# End a span. Records duration. Returns elapsed milliseconds.
sub end_span {
    my ($self, $id) = @_;
    $id //= pop @{$self->{_active}};
    return 0 unless $id && $self->{_spans}{$id};

    my $now = clock_gettime(CLOCK_MONOTONIC);
    my $span = delete $self->{_spans}{$id};
    my $duration_ms = ($now - $span->{started_at}) * 1000;

    $self->_dbh->do(
        'UPDATE trace_spans SET ended_at=?, duration_ms=? WHERE id=?',
        undef, $now, $duration_ms, $id);

    # Remove from active stack (may not be top — end out of order).
    @{$self->{_active}} = grep { $_ ne $id } @{$self->{_active}};

    return $duration_ms;
}

# Get the current active span id.
sub current_span { return $_[0]->{_active}[-1] }

# Execute a code block inside a span. Returns the code's return value.
sub trace {
    my ($self, $name, $code, %meta) = @_;
    my $id = $self->start_span($name, %meta);
    my @result = eval { $code->() };
    my $err = $@;
    $self->end_span($id);
    die $err if $err;
    return wantarray ? @result : $result[0];
}

# === QUERY API ===

# Get a single span with its children.
sub get_span {
    my ($self, $id) = @_;
    my $row = $self->_dbh->selectrow_hashref(
        'SELECT * FROM trace_spans WHERE id=?', undef, $id);
    return undef unless $row;
    $row->{metadata} = jdecode($row->{metadata});
    $row->{children} = $self->_dbh->selectall_arrayref(
        'SELECT * FROM trace_spans WHERE parent_id=? ORDER BY started_at',
        { Slice => {} }, $id);
    $_->{metadata} = jdecode($_->{metadata}) for @{$row->{children}};
    return $row;
}

# Query spans with filters. Returns arrayref.
sub query_spans {
    my ($self, %args) = @_;
    my (@where, @bind);

    push @where, 'topic = ?'    and push @bind, $args{topic}    if $args{topic};
    push @where, 'name LIKE ?'  and push @bind, $args{name}     if $args{name};
    push @where, 'parent_id IS NULL' if $args{root_only};

    if (defined $args{since}) {
        push @where, 'started_at >= ?' and push @bind, $args{since};
    }
    if (defined $args{until}) {
        push @where, 'started_at <= ?' and push @bind, $args{until};
    }
    if (defined $args{min_duration_ms}) {
        push @where, 'duration_ms >= ?' and push @bind, $args{min_duration_ms};
    }

    my $sql = 'SELECT * FROM trace_spans';
    $sql .= ' WHERE ' . join(' AND ', @where) if @where;
    $sql .= ' ORDER BY started_at DESC';
    $sql .= ' LIMIT ?';
    push @bind, $args{limit} // 100;

    my $rows = $self->_dbh->selectall_arrayref($sql, { Slice => {} }, @bind);
    $_->{metadata} = jdecode($_->{metadata}) for @$rows;
    return $rows;
}

# Get the full trace tree (all root spans with children).
sub trace_tree {
    my ($self, %args) = @_;
    my $roots = $self->query_spans(root_only => 1, %args);
    for my $root (@$roots) {
        $root->{children} = $self->_get_children($root->{id});
    }
    return $roots;
}

sub _get_children {
    my ($self, $parent_id) = @_;
    my $rows = $self->_dbh->selectall_arrayref(
        'SELECT * FROM trace_spans WHERE parent_id=? ORDER BY started_at',
        { Slice => {} }, $parent_id);
    for my $row (@$rows) {
        $row->{metadata} = jdecode($row->{metadata});
        $row->{children} = $self->_get_children($row->{id});
    }
    return $rows;
}

# Summary stats: total spans, avg duration, by topic.
sub stats {
    my ($self) = @_;
    my $dbh = $self->_dbh;
    my $total = $dbh->selectrow_array('SELECT COUNT(*) FROM trace_spans');
    my $avg   = $dbh->selectrow_array('SELECT AVG(duration_ms) FROM trace_spans WHERE duration_ms IS NOT NULL');
    my $topics = $dbh->selectall_arrayref(
        'SELECT topic, COUNT(*) as cnt, AVG(duration_ms) as avg_ms FROM trace_spans WHERE topic IS NOT NULL GROUP BY topic ORDER BY cnt DESC',
        { Slice => {} });
    return {
        total_spans   => $total,
        avg_duration  => $avg,
        by_topic      => $topics,
    };
}

# === AUTO-SUBSCRIBE (bus integration) ===

# Subscribe to bus events and trace them automatically.
sub _auto_subscribe {
    my ($self) = @_;
    return unless $self->{bus};

    # Trace all events: start span on event, end on next event or after handler.
    $self->{bus}->subscribe('*', sub {
        my ($ev) = @_;
        my $topic = $ev->{topic};
        my $id = $self->start_span($topic,
            topic     => $topic,
            sender    => $ev->{sender},
            event_id  => $ev->{id},
        );
        # End immediately (bus dispatch is synchronous).
        # For longer operations, use manual start_span/end_span.
        $self->end_span($id);
        return undef;
    }, name => 'tracer');
}

1;

__END__

=encoding utf-8

=head1 NAME

Clam::Tracer — event-trace log for pipeline observability. Records who
called what, when, and how long it took.

=head1 SYNOPSIS

  use Clam::Tracer;

  my $t = Clam::Tracer->new(store => $store);

  # Manual tracing:
  my $id = $t->start_span('llm.call', model => 'gpt-4o');
  my $resp = $provider->post_json('/chat/completions', $payload);
  $t->end_span($id);

  # Convenience wrapper:
  my $result = $t->trace('rule.fire', sub { $engine->chain }, rule => 'ancestor');

  # Query:
  my $spans = $t->query_spans(topic => 'llm', min_duration_ms => 100);
  my $tree  = $t->trace_tree;    # full trace tree (roots + children)
  my $stats = $t->stats;         # { total_spans, avg_duration, by_topic }

  # Auto-subscribe to bus events:
  my $t = Clam::Tracer->new(store => $store, bus => $bus, auto_subscribe => 1);

=head1 DESCRIPTION

Clam::Tracer makes the LLM -> rules -> world model -> crystallization
pipeline visible. It records spans (name, parent, duration, metadata)
in SQLite for post-hoc query.

Two modes:

=over 4

=item Manual — C<start_span>/C<end_span> around code blocks, or C<trace()>
which wraps a code block.

=item Auto — C<auto_subscribe> hooks into the bus and traces every event.

=back

Spans nest: each C<start_span> records the current active span as its
parent. C<end_span> pops the most recent span, or you can pass an id.

=head1 METHODS

=head2 new(%args)

Constructor. Required: C<store>. Optional: C<bus>, C<auto_subscribe>.

=head2 start_span($name, %metadata)

Start a span. Returns span id. If C<topic> is in metadata, it's stored
as a separate column for fast filtering.

=head2 end_span($id)

End a span by id. If C<$id> is omitted, pops the most recent active span.
Returns elapsed milliseconds.

=head2 trace($name, $code, %metadata)

Execute C<$code> inside a span. Returns the code's return value. Propagates
exceptions after ending the span.

=head2 current_span

Returns the id of the currently active span (top of stack).

=head2 get_span($id)

Returns a span with its children (hashref with C<metadata> decoded).

=head2 query_spans(%filters)

Query spans. Filters: C<topic>, C<name> (LIKE), C<root_only>,
C<since>, C<until>, C<min_duration_ms>, C<limit> (default 100).

=head2 trace_tree(%filters)

All root spans with children nested. Same filters as C<query_spans>.

=head2 stats

Returns C<{ total_spans, avg_duration, by_topic }>.

=head1 SEE ALSO

L<Clam::Bus>, L<Clam::Store>, L<Clam::Governor>

=cut
