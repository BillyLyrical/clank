# AI::Clam::Cache — TTL cache for LLM responses and world model queries.
#
# Key is SHA256(model + messages_hash + tools_hash). Prevents re-asking
# the same question to the same model. Also useful for world model
# queries that return stable results.
#
# Storage: SQLite via AI::Clam::Store. Entries expire after TTL.
# Lazy eviction on get; explicit cleanup via purge().
package AI::Clam::Cache;
use strict;
use warnings;
use AI::Clam::Util qw(uuid4 jencode jdecode);
use Digest::SHA qw(sha256_hex);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);

sub new {
    my ($class, %args) = @_;
    my $store = $args{store} // die "AI::Clam::Cache requires store\n";
    my $self = bless {
        store     => $store,
        bus       => $args{bus},
        ttl_ms    => $args{ttl_ms} // 3_600_000,   # 1 hour default
        max_entries => $args{max_entries} // 10_000,
        namespace   => $args{namespace} // 'llm',   # llm|worldmodel|general
        _stats      => { hits => 0, misses => 0, sets => 0, evictions => 0 },
    }, $class;
    $self->_init_schema;
    return $self;
}

sub _dbh { $_[0]->{store}->dbh }

sub _now_ms { int(clock_gettime(CLOCK_MONOTONIC) * 1000) }

sub _init_schema {
    my ($self) = @_;
    $self->_dbh->do(qq{
CREATE TABLE IF NOT EXISTS cache_entries (
  id TEXT PRIMARY KEY,
  namespace TEXT NOT NULL,
  key TEXT NOT NULL,
  value TEXT NOT NULL,
  model TEXT,
  size_bytes INTEGER DEFAULT 0,
  ttl_ms INTEGER,
  created_at INTEGER,
  expires_at INTEGER
)});
    $self->_dbh->do(qq{
CREATE UNIQUE INDEX IF NOT EXISTS idx_cache_ns_key ON cache_entries(namespace, key)});
    $self->_dbh->do(qq{
CREATE INDEX IF NOT EXISTS idx_cache_expires ON cache_entries(expires_at)});
}

# === PUBLIC API ===

# Look up a cached value. Returns undef on miss.
sub get {
    my ($self, $key) = @_;
    my $now = _now_ms();

    my $row = $self->_dbh->selectrow_hashref(
        'SELECT * FROM cache_entries WHERE namespace=? AND key=?',
        undef, $self->{namespace}, $key);

    if ($row) {
        if ($row->{expires_at} && $row->{expires_at} < $now) {
            # Expired — evict lazily.
            $self->_dbh->do('DELETE FROM cache_entries WHERE id=?', undef, $row->{id});
            $self->{_stats}{evictions}++;
            $self->_publish('cache.miss', { key => $key, reason => 'expired' });
            return undef;
        }
        $self->{_stats}{hits}++;
        $self->_publish('cache.hit', { key => $key, model => $row->{model} });
        return jdecode($row->{value});
    }

    $self->{_stats}{misses}++;
    $self->_publish('cache.miss', { key => $key, reason => 'not_found' });
    return undef;
}

# Store a value. Overwrites existing entry for the same key.
sub set {
    my ($self, $key, $value, %args) = @_;
    my $now = _now_ms();
    my $ttl = $args{ttl_ms} // $self->{ttl_ms};
    my $model = $args{model};
    my $json = jencode($value);
    my $id = uuid4();

    $self->_dbh->do(
        'DELETE FROM cache_entries WHERE namespace=? AND key=?',
        undef, $self->{namespace}, $key);

    $self->_dbh->prepare(
        'INSERT INTO cache_entries (id,namespace,key,value,model,size_bytes,ttl_ms,created_at,expires_at) VALUES (?,?,?,?,?,?,?,?,?)'
    )->execute($id, $self->{namespace}, $key, $json, $model,
               length($json), $ttl, $now, $ttl ? $now + $ttl : undef);

    $self->{_stats}{sets}++;
    $self->_maybe_evict;
    return 1;
}

# Invalidate a specific key.
sub invalidate {
    my ($self, $key) = @_;
    my $n = $self->_dbh->do(
        'DELETE FROM cache_entries WHERE namespace=? AND key=?',
        undef, $self->{namespace}, $key);
    return $n;
}

# Invalidate all entries in this namespace.
sub clear {
    my ($self) = @_;
    $self->_dbh->do('DELETE FROM cache_entries WHERE namespace=?', undef, $self->{namespace});
}

# Purge all expired entries across all namespaces.
sub purge {
    my ($self) = @_;
    my $now = _now_ms();
    my $n = $self->_dbh->do(
        'DELETE FROM cache_entries WHERE expires_at IS NOT NULL AND expires_at < ?',
        undef, $now);
    return $n;
}

# Stats: hits, misses, sets, evictions, total entries.
sub stats {
    my ($self) = @_;
    my $count = $self->_dbh->selectrow_array(
        'SELECT COUNT(*) FROM cache_entries WHERE namespace=?',
        undef, $self->{namespace});
    my $total = $self->_dbh->selectrow_array('SELECT COUNT(*) FROM cache_entries');
    return {
        %{$self->{_stats}},
        entries      => $count,
        total_entries => $total,
        hit_rate     => $self->{_stats}{hits} + $self->{_stats}{misses}
            ? $self->{_stats}{hits} / ($self->{_stats}{hits} + $self->{_stats}{misses})
            : 0,
    };
}

# === KEY GENERATION ===

# Build a cache key from LLM request components.
sub make_key {
    my ($class, %args) = @_;
    my $model    = $args{model} // '';
    my $messages = $args{messages};
    my $tools    = $args{tools};
    my $extra    = $args{extra} // '';

    my $msg_hash = ref $messages eq 'ARRAY'
        ? sha256_hex(jencode($messages))
        : sha256_hex($messages // '');
    my $tool_hash = ref $tools eq 'ARRAY'
        ? sha256_hex(jencode($tools))
        : '';

    return sha256_hex("$model:$msg_hash:$tool_hash:$extra");
}

# === INTERNAL ===

sub _maybe_evict {
    my ($self) = @_;
    my $count = $self->_dbh->selectrow_array(
        'SELECT COUNT(*) FROM cache_entries WHERE namespace=?',
        undef, $self->{namespace});
    return if $count <= $self->{max_entries};

    # Evict oldest 10%.
    my $to_evict = int($count * 0.1) || 1;
    $self->_dbh->do(
        'DELETE FROM cache_entries WHERE id IN (SELECT id FROM cache_entries WHERE namespace=? ORDER BY created_at ASC LIMIT ?)',
        undef, $self->{namespace}, $to_evict);
    $self->{_stats}{evictions} += $to_evict;
}

sub _publish {
    my ($self, $topic, $payload) = @_;
    return unless $self->{bus};
    eval { $self->{bus}->publish($topic, $payload, sender => 'cache') };
}

1;

__END__

=encoding utf-8

=head1 NAME

AI::Clam::Cache — TTL cache for LLM responses and world model queries.
Prevents re-asking the same question to the same model.

=head1 SYNOPSIS

  use AI::Clam::Cache;

  my $cache = AI::Clam::Cache->new(
      store       => $store,
      bus         => $bus,            # optional: for cache.hit/miss events
      namespace   => 'llm',           # llm|worldmodel|general
      ttl_ms      => 3_600_000,       # 1 hour
      max_entries => 10_000,
  );

  # LLM response caching:
  my $key = AI::Clam::Cache->make_key(
      model    => 'gpt-4o',
      messages => [{ role => 'user', content => 'what is 2+2?' }],
  );
  my $cached = $cache->get($key);
  unless ($cached) {
      my $resp = $provider->post_json('/chat/completions', $payload);
      $cache->set($key, $resp, model => 'gpt-4o');
  }

  # World model query caching:
  my $wm_cache = AI::Clam::Cache->new(store => $store, namespace => 'worldmodel');
  my $key = sha256_hex("entities:concept");
  my $result = $wm_cache->get($key);

  # Stats:
  my $s = $cache->stats;
  # { hits, misses, sets, evictions, entries, hit_rate }

=head1 DESCRIPTION

AI::Clam::Cache is a TTL cache backed by SQLite. It stores arbitrary Perl
structures as JSON in a C<cache_entries> table. Entries expire after
C<ttl_ms> milliseconds (default 1 hour).

Keys are SHA256 hashes. Use C<make_key> to build deterministic keys from
LLM request components (model + messages + tools).

Namespaces isolate different cache domains (llm, worldmodel, general).
Each namespace has its own max_entries limit with LRU-style eviction
(oldest 10% removed when limit exceeded).

When a bus is provided, the cache publishes C<cache.hit> and C<cache.miss>
events for observability.

=head1 METHODS

=head2 new(%args)

Constructor. Required: C<store>. Optional: C<bus>, C<namespace>,
C<ttl_ms>, C<max_entries>.

=head2 get($key)

Look up a cached value. Returns undef on miss or expiry. Lazily evicts
expired entries.

=head2 set($key, $value, %args)

Store a value. Options: C<ttl_ms> (override default), C<model> (metadata).
Overwrites existing entry for the same key.

=head2 invalidate($key)

Remove a specific entry.

=head2 clear

Remove all entries in this namespace.

=head2 purge

Remove all expired entries across all namespaces. Returns count removed.

=head2 stats

Returns C<{ hits, misses, sets, evictions, entries, total_entries, hit_rate }>.

=head2 make_key(%args)

Class method. Build a deterministic cache key from C<model>, C<messages>,
C<tools>, and optional C<extra>.

=head1 SEE ALSO

L<AI::Clam::Provider>, L<AI::Clam::Store>, L<AI::Clam::Governor>

=cut
