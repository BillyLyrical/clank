# SQLite store: sessions, message tree, event journal, kv, rag+FTS5.
package Clam::Store;
use strict;
use warnings;
use DBI;
use Clam::Util qw(uuid4 now_ms jencode jdecode ensure_dir);

sub new {
    my ($class, %args) = @_;
    my $path = $args{path} // ':memory:';
    if ($path ne ':memory:') {
        (my $dir = $path) =~ s{/[^/]+$}{};
        ensure_dir($dir) if length $dir;
    }
    my $dbh = DBI->connect("dbi:SQLite:dbname=$path", '', '', {
        RaiseError => 1, AutoCommit => 1, PrintError => 0,
    }) or die "Clam::Store: cannot open $path: $DBI::errstr";
    $dbh->do('PRAGMA journal_mode=WAL') if $path ne ':memory:';
    $dbh->do('PRAGMA foreign_keys=ON');
    my $self = bless { dbh => $dbh, path => $path }, $class;
    $self->_init_schema;
    return $self;
}

sub _init_schema {
    my ($self) = @_;
    my $db = $self->{dbh};
    # NOTE: DBI do() executes only the FIRST statement of a string — one call each.
    $db->do(qq{
CREATE TABLE IF NOT EXISTS sessions (
  id TEXT PRIMARY KEY,
  title TEXT,
  cwd TEXT,
  model TEXT,
  leaf_id TEXT,                  -- current conversation position in the tree
  created_at INTEGER,
  updated_at INTEGER
)});
    # Migration for pre-leaf_id databases.
    my @cols = map { $_->[1] } @{ $db->selectall_arrayref('PRAGMA table_info(sessions)') };
    $db->do('ALTER TABLE sessions ADD COLUMN leaf_id TEXT') unless grep { $_ eq 'leaf_id' } @cols;
    $db->do(qq{
CREATE TABLE IF NOT EXISTS messages (
  id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  parent_id TEXT,
  role TEXT NOT NULL,            -- user|assistant|toolResult|custom|compaction
  content TEXT NOT NULL,         -- JSON: message body
  created_at INTEGER
)});
    $db->do(qq{CREATE INDEX IF NOT EXISTS idx_messages_session ON messages(session_id, id)});
    $db->do(qq{
CREATE TABLE IF NOT EXISTS events (
  id TEXT PRIMARY KEY,
  correlation_id TEXT,
  topic TEXT NOT NULL,
  sender TEXT,
  payload TEXT,
  created_at INTEGER
)});
    $db->do(qq{CREATE INDEX IF NOT EXISTS idx_events_topic ON events(topic, created_at)});
    $db->do(qq{
CREATE TABLE IF NOT EXISTS kv (
  key TEXT PRIMARY KEY,
  value TEXT
)});
    # Facts: shared blackboard state for Clam::Rules. One row per asserted fact;
    # attributes is a JSON hashref so every agent on this DB reads/writes the
    # same structured space (the Minsky blackboard).
$db->do(qq{
CREATE TABLE IF NOT EXISTS facts (
  id TEXT PRIMARY KEY,
  type TEXT NOT NULL,
  attributes TEXT,          -- JSON: hashref of fact attributes
  asserted_by TEXT,         -- who/what asserted it (rule name, agent, 'external')
  created_at INTEGER
)});
$db->do(qq{CREATE INDEX IF NOT EXISTS idx_facts_type ON facts(type)});
    # RAG: documents + FTS5 index (guarded; FTS5 may be absent in old builds)
    my $has_fts = eval {
        $db->do("CREATE VIRTUAL TABLE IF NOT EXISTS _fts_probe USING fts5(x)");
        $db->do("DROP TABLE IF EXISTS _fts_probe");
        1;
    };
    if ($has_fts) {
        $self->{has_fts} = 1;
        $db->do(qq{
CREATE TABLE IF NOT EXISTS rag_documents (
  id TEXT PRIMARY KEY,
  source TEXT,                   -- file path or url
  chunk_index INTEGER DEFAULT 0,
  chunk_text TEXT NOT NULL,
  metadata TEXT,
  created_at INTEGER
)});
        $db->do(qq{
CREATE VIRTUAL TABLE IF NOT EXISTS rag_fts USING fts5(
  chunk_text, content='rag_documents', content_rowid='rowid'
)});
        # triggers contain ';' inside BEGIN...END — one do() each
        $db->do(<<'SQL');
CREATE TRIGGER IF NOT EXISTS rag_ai AFTER INSERT ON rag_documents BEGIN
  INSERT INTO rag_fts(rowid, chunk_text) VALUES (new.rowid, new.chunk_text);
END;
SQL
        $db->do(<<'SQL');
CREATE TRIGGER IF NOT EXISTS rag_ad AFTER DELETE ON rag_documents BEGIN
  INSERT INTO rag_fts(rag_fts, rowid, chunk_text) VALUES('delete', old.rowid, old.chunk_text);
END;
SQL
    } else {
        $self->{has_fts} = 0;
        $db->do(<<'SQL');
CREATE TABLE IF NOT EXISTS rag_documents (
  id TEXT PRIMARY KEY, source TEXT, chunk_index INTEGER DEFAULT 0,
  chunk_text TEXT NOT NULL, metadata TEXT, created_at INTEGER
);
SQL
    }
    # Wit registry: tracks installed wits discovered via # CLAM-WIT: markers.
    # The comment is source of truth; this table is the runtime cache.
    $db->do(qq{
CREATE TABLE IF NOT EXISTS wits (
  name TEXT PRIMARY KEY,
  version TEXT,
  about TEXT,
  usage TEXT,
  hint TEXT,
  author TEXT,
  license TEXT,
  path TEXT,
  state TEXT DEFAULT 'available',   -- available|active|disabled
  loaded_at INTEGER,
  created_at INTEGER
)});
}

sub dbh { $_[0]->{dbh} }
sub path { $_[0]->{path} }
sub has_fts { $_[0]->{has_fts} ? 1 : 0 }

# --- sessions -------------------------------------------------------------
sub create_session {
    my ($self, %a) = @_;
    my $id = uuid4();
    my $now = now_ms();
    $self->{dbh}->prepare(
        'INSERT INTO sessions (id,title,cwd,model,created_at,updated_at) VALUES (?,?,?,?,?,?)'
    )->execute($id, $a{title}, $a{cwd}, $a{model}, $now, $now);
    return $id;
}

sub get_session {
    my ($self, $id) = @_;
    my $st = $self->{dbh}->prepare('SELECT * FROM sessions WHERE id=?');
    $st->execute($id);
    my $r = $st->fetchrow_hashref;
    return $r;
}

sub list_sessions {
    my ($self, %a) = @_;
    my ($sql, @b) = ('SELECT * FROM sessions', '');
    if ($a{cwd}) { $sql .= ' WHERE cwd=?'; push @b, $a{cwd} }
    $sql .= ' ORDER BY updated_at DESC LIMIT ?';
    push @b, $a{limit} // 50;
    my $st = $self->{dbh}->prepare($sql);
    $st->execute(@b);
    # fetchall_arrayref already returns an arrayref — do not double-wrap.
    return $st->fetchall_arrayref({});
}

sub touch_session {
    my ($self, $id) = @_;
    $self->{dbh}->do('UPDATE sessions SET updated_at=? WHERE id=?', undef, now_ms(), $id);
}

sub set_session_title {
    my ($self, $id, $title) = @_;
    $self->{dbh}->do('UPDATE sessions SET title=?, updated_at=? WHERE id=?',
        undef, $title, now_ms(), $id);
}

# --- messages (tree via parent_id) ----------------------------------------
sub append_message {
    my ($self, %a) = @_;
    my $id = uuid4();
    # content is ALWAYS stored as JSON (allow_nonref encodes plain strings too),
    # so get_message can decode uniformly.
    my $content = jencode($a{content});
    $self->{dbh}->prepare(
        'INSERT INTO messages (id,session_id,parent_id,role,content,created_at) VALUES (?,?,?,?,?,?)'
    )->execute($id, $a{session_id}, $a{parent_id}, $a{role}, $content, now_ms());
    $self->touch_session($a{session_id});
    return $id;
}

sub get_message {
    my ($self, $id) = @_;
    my $st = $self->{dbh}->prepare('SELECT * FROM messages WHERE id=?');
    $st->execute($id);
    my $r = $st->fetchrow_hashref or return undef;
    # content is JSON; fall back to the raw string for rows written before the
    # uniform-JSON change (plain-text user messages).
    my $d = jdecode($r->{content});
    $r->{content} = defined $d ? $d : $r->{content};
    return $r;
}

# Walk parent chain from leaf to root, return messages root-first.
sub message_path {
    my ($self, $session_id, $leaf_id) = @_;
    my %seen;
    my @chain;
    my $cur = defined $leaf_id ? $leaf_id : $self->leaf_message($session_id);
    while (defined $cur && !$seen{$cur}++) {
        my $m = $self->get_message($cur) or last;
        unshift @chain, $m;
        $cur = $m->{parent_id};
    }
    return \@chain;
}

# The session's current conversation position (tracked leaf). Falls back to
# the newest message by rowid for sessions with no tracked leaf yet — rowid is
# monotonic per table, reliable even when inserts share a millisecond.
sub leaf_message {
    my ($self, $session_id) = @_;
    my $st = $self->{dbh}->prepare('SELECT leaf_id FROM sessions WHERE id=?');
    $st->execute($session_id);
    my $leaf = $st->fetchrow_array;
    return $leaf if defined $leaf && length $leaf;
    $st = $self->{dbh}->prepare(
        'SELECT id FROM messages WHERE session_id=? ORDER BY rowid DESC LIMIT 1');
    $st->execute($session_id);
    return $st->fetchrow_array;
}

# Move the conversation position to a message in this session.
sub set_leaf {
    my ($self, $session_id, $message_id) = @_;
    $self->{dbh}->do('UPDATE sessions SET leaf_id=? WHERE id=?', undef, $message_id, $session_id);
}

sub count_messages {
    my ($self, $session_id) = @_;
    my $st = $self->{dbh}->prepare('SELECT COUNT(*) FROM messages WHERE session_id=?');
    $st->execute($session_id);
    return $st->fetchrow_array;
}

# --- event journal (blackboard persistence) --------------------------------
sub log_event {
    my ($self, %a) = @_;
    my $id = uuid4();
    my $payload = ref($a{payload}) ? jencode($a{payload}) : ($a{payload} // '');
    $self->{dbh}->prepare(
        'INSERT INTO events (id,correlation_id,topic,sender,payload,created_at) VALUES (?,?,?,?,?,?)'
    )->execute($id, $a{correlation_id}, $a{topic}, $a{sender}, $payload, now_ms());
    return $id;
}

sub query_events {
    my ($self, %a) = @_;
    my (@w, @b);
    push @w, 'topic LIKE ?' if defined $a{topic};
    push @b, $a{topic}     if defined $a{topic};
    push @w, 'correlation_id=?' if defined $a{correlation_id};
    push @b, $a{correlation_id} if defined $a{correlation_id};
    my $sql = 'SELECT * FROM events';
    $sql .= ' WHERE ' . join(' AND ', @w) if @w;
    $sql .= ' ORDER BY created_at ASC LIMIT ?';
    push @b, $a{limit} // 200;
    my $st = $self->{dbh}->prepare($sql);
    $st->execute(@b);
    my @rows = map { my %h = %$_; $h{payload} = jdecode($_->{payload}); \%h }
               @{ $st->fetchall_arrayref({}) };
    return \@rows;
}

# --- kv --------------------------------------------------------------------
sub kv_set {
    my ($self, $key, $value) = @_;
    $value = ref($value) ? jencode($value) : $value;
    $self->{dbh}->do(
        'INSERT INTO kv (key,value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value',
        undef, $key, $value);
}

sub kv_get {
    my ($self, $key) = @_;
    my $st = $self->{dbh}->prepare('SELECT value FROM kv WHERE key=?');
    $st->execute($key);
    my $v = $st->fetchrow_array;
    return undef unless defined $v;
    my $d = jdecode($v);
    return defined $d ? $d : $v;   # not JSON -> raw string
}

# --- facts (Clam::Rules blackboard) ----------------------------------------
# One row per asserted fact. attributes is stored as a JSON hashref so every
# agent/process on this DB shares one structured space. The store is the source
# of truth; Clam::Rules::Engine keeps an in-memory working set over it.

sub assert_fact {
    my ($self, $type, $attributes, $meta) = @_;
    $attributes //= {};
    $meta       //= {};
    my $id = uuid4();
    $self->{dbh}->prepare(
        'INSERT INTO facts (id,type,attributes,asserted_by,created_at) VALUES (?,?,?,?,?)'
    )->execute($id, $type, jencode($attributes),
               $meta->{asserted_by} // 'external', now_ms());
    return $id;
}

sub retract_fact {
    my ($self, $fact_id) = @_;
    $self->{dbh}->do('DELETE FROM facts WHERE id=?', undef, $fact_id);
    return 1;
}

# Query facts by type (all types if omitted). Returns decoded rows (arrayref of
# {id,type,attributes,asserted_by,created_at}).
sub query_facts {
    my ($self, $type) = @_;
    my ($sql, @b);
    if (defined $type) {
        $sql = 'SELECT * FROM facts WHERE type=? ORDER BY created_at';
        @b   = ($type);
    } else {
        $sql = 'SELECT * FROM facts ORDER BY created_at';
    }
    my $st = $self->{dbh}->prepare($sql);
    $st->execute(@b);
    return [ map { _decode_fact($_) } @{ $st->fetchall_arrayref({}) } ];
}

sub all_facts { $_[0]->query_facts() }

sub fact_count {
    my ($self, $type) = @_;
    my ($sql, @b);
    if (defined $type) {
        $sql = 'SELECT COUNT(*) FROM facts WHERE type=?';
        @b   = ($type);
    } else {
        $sql = 'SELECT COUNT(*) FROM facts';
    }
    my $st = $self->{dbh}->prepare($sql);
    $st->execute(@b);
    return $st->fetchrow_array;
}

sub clear_facts {
    my ($self) = @_;
    $self->{dbh}->do('DELETE FROM facts');
    return 1;
}

sub _decode_fact {
    my ($row) = @_;
    my %h = %$row;
    $h{attributes} = (defined $row->{attributes} && length $row->{attributes})
        ? jdecode($row->{attributes}) : {};
    return \%h;
}

# --- rag -------------------------------------------------------------------
sub rag_add {
    my ($self, %a) = @_;
    return 0 unless $self->{has_fts};
    my $id = uuid4();
    $self->{dbh}->prepare(
        'INSERT INTO rag_documents (id,source,chunk_index,chunk_text,metadata,created_at) VALUES (?,?,?,?,?,?)'
    )->execute($id, $a{source}, $a{chunk_index} // 0, $a{chunk_text},
               ref($a{metadata}) ? jencode($a{metadata}) : ($a{metadata} // undef), now_ms());
    return 1;
}

sub rag_search {
    my ($self, $query, %a) = @_;
    return [] unless $self->{has_fts};
    my $limit = $a{limit} // 5;
    # sanitize: quote each word for FTS5 MATCH
    my @words = grep { length } split /\s+/, $query;
    return [] unless @words;
    my $match = join(' ', map { '"' . ($_ =~ s/"/""/gr) . '"' } @words);
    my $st = $self->{dbh}->prepare(<<'SQL');
SELECT d.id, d.source, d.chunk_index, d.chunk_text,
       bm25(rag_fts) AS rank
FROM rag_fts f JOIN rag_documents d ON d.rowid = f.rowid
WHERE rag_fts MATCH ? ORDER BY rank LIMIT ?
SQL
    $st->execute($match, $limit);
    # fetchall_arrayref already returns an arrayref — do not double-wrap.
    return $st->fetchall_arrayref({});
}

# --- wit registry -----------------------------------------------------------
sub wit_insert {
    my ($self, %a) = @_;
    $self->{dbh}->prepare(
        'INSERT INTO wits (name,version,about,usage,hint,author,license,path,state,created_at) VALUES (?,?,?,?,?,?,?,?,?,?)'
    )->execute($a{name}, $a{version}, $a{about}, $a{usage}, $a{hint},
               $a{author}, $a{license}, $a{path}, $a{state} // 'available', now_ms());
    return 1;
}

sub wit_update {
    my ($self, %a) = @_;
    my @sets;
    for my $k (qw(version about usage hint path state)) {
        push @sets, "$k=?" if exists $a{$k};
    }
    return 0 unless @sets;
    my $sql = "UPDATE wits SET " . join(', ', @sets) . " WHERE name=?";
    my @vals = map { $a{$_} } grep { exists $a{$_} } qw(version about usage hint path state);
    push @vals, $a{name};
    $self->{dbh}->prepare($sql)->execute(@vals);
    return 1;
}

sub wit_get {
    my ($self, $name) = @_;
    my $row = $self->{dbh}->selectrow_hashref('SELECT * FROM wits WHERE name=?', undef, $name);
    return $row;
}

sub wit_list {
    my ($self, %o) = @_;
    my $where = '';
    my @bind;
    if ($o{state}) {
        $where = 'WHERE state=?';
        push @bind, $o{state};
    }
    my $st = $self->{dbh}->prepare("SELECT * FROM wits $where ORDER BY name");
    $st->execute(@bind);
    return $st->fetchall_arrayref({});
}

sub wit_set_state {
    my ($self, $name, $state) = @_;
    $self->{dbh}->prepare('UPDATE wits SET state=?, loaded_at=? WHERE name=?')
        ->execute($state, $state eq 'active' ? now_ms() : undef, $name);
    return 1;
}

sub wit_remove {
    my ($self, $name) = @_;
    $self->{dbh}->prepare('DELETE FROM wits WHERE name=?')->execute($name);
    return 1;
}

1;
