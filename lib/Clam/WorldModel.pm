# World model: entities, relations, temporal facts, causal links, beliefs.
# Extends Clam::Store with structured knowledge representation.
package Clam::WorldModel;
use strict;
use warnings;
use Clam::Util qw(now_ms jencode jdecode);

sub new {
    my ($class, %args) = @_;
    my $store = $args{store} or die "Clam::WorldModel requires store";
    my $self = bless { store => $store, dbh => $store->dbh }, $class;
    $self->_init_schema;
    return $self;
}

sub dbh { $_[0]->{dbh} }

sub _init_schema {
    my ($self) = @_;
    my $db = $self->{dbh};

    $db->do(qq{
CREATE TABLE IF NOT EXISTS wm_entities (
    id          TEXT PRIMARY KEY,
    type        TEXT NOT NULL,
    name        TEXT,
    attributes  TEXT,
    created_at  INTEGER,
    updated_at  INTEGER
)});
    $db->do(qq{CREATE INDEX IF NOT EXISTS idx_wm_entities_type ON wm_entities(type)});
    $db->do(qq{CREATE INDEX IF NOT EXISTS idx_wm_entities_name ON wm_entities(name)});

    $db->do(qq{
CREATE TABLE IF NOT EXISTS wm_relations (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    source_id   TEXT NOT NULL REFERENCES wm_entities(id) ON DELETE CASCADE,
    target_id   TEXT NOT NULL REFERENCES wm_entities(id) ON DELETE CASCADE,
    type        TEXT NOT NULL,
    attributes  TEXT,
    confidence  REAL DEFAULT 1.0,
    created_at  INTEGER,
    valid_until INTEGER
)});
    $db->do(qq{CREATE INDEX IF NOT EXISTS idx_wm_relations_source ON wm_relations(source_id)});
    $db->do(qq{CREATE INDEX IF NOT EXISTS idx_wm_relations_target ON wm_relations(target_id)});
    $db->do(qq{CREATE INDEX IF NOT EXISTS idx_wm_relations_type ON wm_relations(type)});

    $db->do(qq{
CREATE TABLE IF NOT EXISTS wm_facts (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    entity_id   TEXT REFERENCES wm_entities(id) ON DELETE CASCADE,
    predicate   TEXT NOT NULL,
    value       TEXT,
    confidence  REAL DEFAULT 1.0,
    source      TEXT,
    valid_from  INTEGER NOT NULL,
    valid_until INTEGER
)});
    $db->do(qq{CREATE INDEX IF NOT EXISTS idx_wm_facts_entity ON wm_facts(entity_id)});
    $db->do(qq{CREATE INDEX IF NOT EXISTS idx_wm_facts_predicate ON wm_facts(predicate)});

    $db->do(qq{
CREATE TABLE IF NOT EXISTS wm_causes (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    cause_entity    TEXT NOT NULL REFERENCES wm_entities(id) ON DELETE CASCADE,
    effect_entity   TEXT NOT NULL REFERENCES wm_entities(id) ON DELETE CASCADE,
    mechanism       TEXT,
    confidence      REAL DEFAULT 1.0,
    evidence        TEXT
)});
    $db->do(qq{CREATE INDEX IF NOT EXISTS idx_wm_causes_cause ON wm_causes(cause_entity)});
    $db->do(qq{CREATE INDEX IF NOT EXISTS idx_wm_causes_effect ON wm_causes(effect_entity)});

    $db->do(qq{
CREATE TABLE IF NOT EXISTS wm_beliefs (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    statement       TEXT NOT NULL,
    confidence      REAL DEFAULT 0.5,
    source          TEXT,
    evidence        TEXT,
    created_at      INTEGER,
    superseded_by   INTEGER REFERENCES wm_beliefs(id)
)});
    $db->do(qq{CREATE INDEX IF NOT EXISTS idx_wm_beliefs_confidence ON wm_beliefs(confidence)});

    # FTS5 indexes (guarded; may be absent in old builds)
    my $has_fts = eval {
        $db->do("CREATE VIRTUAL TABLE IF NOT EXISTS _wm_fts_probe USING fts5(x)");
        $db->do("DROP TABLE IF EXISTS _wm_fts_probe");
        1;
    };
    if ($has_fts) {
        $self->{has_fts} = 1;

        # Entity FTS: search by name + attributes
        $db->do(qq{
CREATE VIRTUAL TABLE IF NOT EXISTS wm_entities_fts USING fts5(
    id UNINDEXED, name, attributes, content='wm_entities', content_rowid='rowid'
)});
        $db->do(<<'SQL');
CREATE TRIGGER IF NOT EXISTS wm_entities_ai AFTER INSERT ON wm_entities BEGIN
  INSERT INTO wm_entities_fts(rowid, id, name, attributes)
    VALUES (new.rowid, new.id, new.name, new.attributes);
END;
SQL
        $db->do(<<'SQL');
CREATE TRIGGER IF NOT EXISTS wm_entities_ad AFTER DELETE ON wm_entities BEGIN
  INSERT INTO wm_entities_fts(wm_entities_fts, rowid, id, name, attributes)
    VALUES ('delete', old.rowid, old.id, old.name, old.attributes);
END;
SQL
        $db->do(<<'SQL');
CREATE TRIGGER IF NOT EXISTS wm_entities_au AFTER UPDATE ON wm_entities BEGIN
  INSERT INTO wm_entities_fts(wm_entities_fts, rowid, id, name, attributes)
    VALUES ('delete', old.rowid, old.id, old.name, old.attributes);
  INSERT INTO wm_entities_fts(rowid, id, name, attributes)
    VALUES (new.rowid, new.id, new.name, new.attributes);
END;
SQL

        # Belief FTS: search by statement
        $db->do(qq{
CREATE VIRTUAL TABLE IF NOT EXISTS wm_beliefs_fts USING fts5(
    id UNINDEXED, statement, source, content='wm_beliefs', content_rowid='rowid'
)});
        $db->do(<<'SQL');
CREATE TRIGGER IF NOT EXISTS wm_beliefs_ai AFTER INSERT ON wm_beliefs BEGIN
  INSERT INTO wm_beliefs_fts(rowid, id, statement, source)
    VALUES (new.rowid, new.id, new.statement, new.source);
END;
SQL
        $db->do(<<'SQL');
CREATE TRIGGER IF NOT EXISTS wm_beliefs_ad AFTER DELETE ON wm_beliefs BEGIN
  INSERT INTO wm_beliefs_fts(wm_beliefs_fts, rowid, id, statement, source)
    VALUES ('delete', old.rowid, old.id, old.statement, old.source);
END;
SQL
        $db->do(<<'SQL');
CREATE TRIGGER IF NOT EXISTS wm_beliefs_au AFTER UPDATE ON wm_beliefs BEGIN
  INSERT INTO wm_beliefs_fts(wm_beliefs_fts, rowid, id, statement, source)
    VALUES ('delete', old.rowid, old.id, old.statement, old.source);
  INSERT INTO wm_beliefs_fts(rowid, id, statement, source)
    VALUES (new.rowid, new.id, new.statement, new.source);
END;
SQL

        # Fact FTS: search by predicate + value
        $db->do(qq{
CREATE VIRTUAL TABLE IF NOT EXISTS wm_facts_fts USING fts5(
    id UNINDEXED, predicate, value, source, content='wm_facts', content_rowid='rowid'
)});
        $db->do(<<'SQL');
CREATE TRIGGER IF NOT EXISTS wm_facts_ai AFTER INSERT ON wm_facts BEGIN
  INSERT INTO wm_facts_fts(rowid, id, predicate, value, source)
    VALUES (new.rowid, new.id, new.predicate, new.value, new.source);
END;
SQL
        $db->do(<<'SQL');
CREATE TRIGGER IF NOT EXISTS wm_facts_ad AFTER DELETE ON wm_facts BEGIN
  INSERT INTO wm_facts_fts(wm_facts_fts, rowid, id, predicate, value, source)
    VALUES ('delete', old.rowid, old.id, old.predicate, old.value, old.source);
END;
SQL
        $db->do(<<'SQL');
CREATE TRIGGER IF NOT EXISTS wm_facts_au AFTER UPDATE ON wm_facts BEGIN
  INSERT INTO wm_facts_fts(wm_facts_fts, rowid, id, predicate, value, source)
    VALUES ('delete', old.rowid, old.id, old.predicate, old.value, old.source);
  INSERT INTO wm_facts_fts(rowid, id, predicate, value, source)
    VALUES (new.rowid, new.id, new.predicate, new.value, new.source);
END;
SQL
    }
}

# ---------------------------------------------------------------------------
# Entity operations
# ---------------------------------------------------------------------------

sub add_entity {
    my ($self, %args) = @_;
    my $id = $args{id} || _gen_id();
    my $now = now_ms();
    my $attrs = ref $args{attributes} eq 'HASH' ? jencode($args{attributes}) : ($args{attributes} // '{}');

    $self->{dbh}->do(
        'INSERT OR REPLACE INTO wm_entities (id, type, name, attributes, created_at, updated_at)
         VALUES (?, ?, ?, ?, COALESCE((SELECT created_at FROM wm_entities WHERE id = ?), ?), ?)',
        undef, $id, $args{type}, $args{name}, $attrs, $id, $now, $now,
    );
    return $id;
}

sub get_entity {
    my ($self, $id) = @_;
    my $row = $self->{dbh}->selectrow_hashref(
        'SELECT * FROM wm_entities WHERE id = ?', undef, $id,
    );
    return undef unless $row;
    $row->{attributes} = jdecode($row->{attributes} // '{}');
    return $row;
}

sub query_entities {
    my ($self, %args) = @_;
    my @where;
    my @bind;

    if (defined $args{type}) {
        push @where, 'type = ?';
        push @bind, $args{type};
    }
    if (defined $args{name}) {
        push @where, 'name = ?';
        push @bind, $args{name};
    }

    my $sql = 'SELECT * FROM wm_entities';
    $sql .= ' WHERE ' . join(' AND ', @where) if @where;
    $sql .= ' ORDER BY updated_at DESC';
    $sql .= " LIMIT $args{limit}" if $args{limit};

    my $rows = $self->{dbh}->selectall_arrayref($sql, { Slice => {} }, @bind);
    for my $r (@$rows) {
        $r->{attributes} = jdecode($r->{attributes} // '{}');
    }
    return $rows;
}

# ---------------------------------------------------------------------------
# Relation operations
# ---------------------------------------------------------------------------

sub add_relation {
    my ($self, %args) = @_;
    my $now = now_ms();
    my $attrs = ref $args{attributes} eq 'HASH' ? jencode($args{attributes}) : ($args{attributes} // '{}');

    $self->{dbh}->do(
        'INSERT INTO wm_relations (source_id, target_id, type, attributes, confidence, created_at)
         VALUES (?, ?, ?, ?, ?, ?)',
        undef, $args{source_id}, $args{target_id}, $args{type},
        $attrs, $args{confidence} // 1.0, $now,
    );
    return $self->{dbh}->last_insert_id(undef, undef, 'wm_relations', 'id');
}

sub get_relations {
    my ($self, %args) = @_;
    my @where;
    my @bind;

    if (defined $args{source_id}) {
        push @where, 'source_id = ?';
        push @bind, $args{source_id};
    }
    if (defined $args{target_id}) {
        push @where, 'target_id = ?';
        push @bind, $args{target_id};
    }
    if (defined $args{type}) {
        push @where, 'type = ?';
        push @bind, $args{type};
    }

    push @where, '(valid_until IS NULL OR valid_until > ?)';
    push @bind, now_ms();

    my $sql = 'SELECT * FROM wm_relations';
    $sql .= ' WHERE ' . join(' AND ', @where) if @where;
    $sql .= ' ORDER BY created_at DESC';

    my $rows = $self->{dbh}->selectall_arrayref($sql, { Slice => {} }, @bind);
    for my $r (@$rows) {
        $r->{attributes} = jdecode($r->{attributes} // '{}');
    }
    return $rows;
}

sub retract_relation {
    my ($self, $id) = @_;
    $self->{dbh}->do(
        'UPDATE wm_relations SET valid_until = ? WHERE id = ?',
        undef, now_ms(), $id,
    );
}

# ---------------------------------------------------------------------------
# Fact operations
# ---------------------------------------------------------------------------

sub assert_fact {
    my ($self, %args) = @_;
    my $now = now_ms();
    my $value = ref $args{value} eq 'HASH' || ref $args{value} eq 'ARRAY'
        ? jencode($args{value}) : ($args{value} // '');

    $self->{dbh}->do(
        'INSERT INTO wm_facts (entity_id, predicate, value, confidence, source, valid_from)
         VALUES (?, ?, ?, ?, ?, ?)',
        undef, $args{entity_id}, $args{predicate}, $value,
        $args{confidence} // 1.0, $args{source} // 'unknown', $now,
    );
    return $self->{dbh}->last_insert_id(undef, undef, 'wm_facts', 'id');
}

sub query_facts {
    my ($self, %args) = @_;
    my @where;
    my @bind;

    if (defined $args{entity_id}) {
        push @where, 'entity_id = ?';
        push @bind, $args{entity_id};
    }
    if (defined $args{predicate}) {
        push @where, 'predicate = ?';
        push @bind, $args{predicate};
    }

    push @where, '(valid_until IS NULL OR valid_until > ?)';
    push @bind, now_ms();

    my $sql = 'SELECT * FROM wm_facts';
    $sql .= ' WHERE ' . join(' AND ', @where) if @where;
    $sql .= ' ORDER BY valid_from DESC';

    my $rows = $self->{dbh}->selectall_arrayref($sql, { Slice => {} }, @bind);
    for my $r (@$rows) {
        $r->{value} = jdecode($r->{value}) if $r->{value} =~ /^[\{\[]/;
    }
    return $rows;
}

sub retract_fact {
    my ($self, $id) = @_;
    $self->{dbh}->do(
        'UPDATE wm_facts SET valid_until = ? WHERE id = ?',
        undef, now_ms(), $id,
    );
}

# Temporal range queries for facts

sub facts_temporal {
    my ($self, %args) = @_;
    my @where;
    my @bind;

    if (defined $args{entity_id}) {
        push @where, 'entity_id = ?';
        push @bind, $args{entity_id};
    }
    if (defined $args{predicate}) {
        push @where, 'predicate = ?';
        push @bind, $args{predicate};
    }

    # valid_from >= from_time (fact existed at or after from_time)
    if (defined $args{from_time}) {
        push @where, 'valid_from >= ?';
        push @bind, $args{from_time};
    }

    # valid_from <= to_time (fact started before to_time)
    if (defined $args{to_time}) {
        push @where, 'valid_from <= ?';
        push @bind, $args{to_time};
    }

    # valid_until IS NULL OR valid_until > to_time (still valid at to_time)
    if (defined $args{to_time}) {
        push @where, '(valid_until IS NULL OR valid_until > ?)';
        push @bind, $args{to_time};
    } else {
        # Default: only currently valid facts
        push @where, '(valid_until IS NULL OR valid_until > ?)';
        push @bind, now_ms();
    }

    my $sql = 'SELECT * FROM wm_facts';
    $sql .= ' WHERE ' . join(' AND ', @where) if @where;
    $sql .= ' ORDER BY valid_from DESC';
    $sql .= " LIMIT $args{limit}" if $args{limit};

    my $rows = $self->{dbh}->selectall_arrayref($sql, { Slice => {} }, @bind);
    for my $r (@$rows) {
        $r->{value} = jdecode($r->{value}) if $r->{value} =~ /^[\{\[]/;
    }
    return $rows;
}

sub facts_at_time {
    my ($self, $time, %args) = @_;
    return $self->facts_temporal(
        to_time   => $time,
        from_time => $args{from_time},
        entity_id => $args{entity_id},
        predicate => $args{predicate},
        limit     => $args{limit},
    );
}

sub fact_history {
    my ($self, %args) = @_;
    my @where;
    my @bind;

    if (defined $args{entity_id}) {
        push @where, 'entity_id = ?';
        push @bind, $args{entity_id};
    }
    if (defined $args{predicate}) {
        push @where, 'predicate = ?';
        push @bind, $args{predicate};
    }

    # Include both current and retracted facts
    my $sql = 'SELECT * FROM wm_facts';
    $sql .= ' WHERE ' . join(' AND ', @where) if @where;
    $sql .= ' ORDER BY valid_from DESC';

    my $rows = $self->{dbh}->selectall_arrayref($sql, { Slice => {} }, @bind);
    for my $r (@$rows) {
        $r->{value} = jdecode($r->{value}) if $r->{value} =~ /^[\{\[]/;
    }
    return $rows;
}

# ---------------------------------------------------------------------------
# Cause operations
# ---------------------------------------------------------------------------

sub add_cause {
    my ($self, %args) = @_;
    my $evidence = ref $args{evidence} eq 'ARRAY' ? jencode($args{evidence}) : ($args{evidence} // '[]');

    $self->{dbh}->do(
        'INSERT INTO wm_causes (cause_entity, effect_entity, mechanism, confidence, evidence)
         VALUES (?, ?, ?, ?, ?)',
        undef, $args{cause_entity}, $args{effect_entity},
        $args{mechanism}, $args{confidence} // 1.0, $evidence,
    );
    return $self->{dbh}->last_insert_id(undef, undef, 'wm_causes', 'id');
}

sub trace_causes {
    my ($self, $effect_id) = @_;
    my $rows = $self->{dbh}->selectall_arrayref(
        'SELECT * FROM wm_causes WHERE effect_entity = ? ORDER BY confidence DESC',
        { Slice => {} }, $effect_id,
    );
    for my $r (@$rows) {
        $r->{evidence} = jdecode($r->{evidence} // '[]');
    }
    return $rows;
}

sub predict_effects {
    my ($self, $cause_id) = @_;
    my $rows = $self->{dbh}->selectall_arrayref(
        'SELECT * FROM wm_causes WHERE cause_entity = ? ORDER BY confidence DESC',
        { Slice => {} }, $cause_id,
    );
    for my $r (@$rows) {
        $r->{evidence} = jdecode($r->{evidence} // '[]');
    }
    return $rows;
}

# ---------------------------------------------------------------------------
# Belief operations
# ---------------------------------------------------------------------------

sub believe {
    my ($self, %args) = @_;
    my $now = now_ms();
    my $evidence = ref $args{evidence} eq 'ARRAY' ? jencode($args{evidence}) : ($args{evidence} // '[]');

    $self->{dbh}->do(
        'INSERT INTO wm_beliefs (statement, confidence, source, evidence, created_at)
         VALUES (?, ?, ?, ?, ?)',
        undef, $args{statement}, $args{confidence} // 0.5,
        $args{source} // 'llm', $evidence, $now,
    );
    return $self->{dbh}->last_insert_id(undef, undef, 'wm_beliefs', 'id');
}

sub query_beliefs {
    my ($self, %args) = @_;
    my @where = 'superseded_by IS NULL';
    my @bind;

    if (defined $args{min_confidence}) {
        push @where, 'confidence >= ?';
        push @bind, $args{min_confidence};
    }
    if (defined $args{source}) {
        push @where, 'source = ?';
        push @bind, $args{source};
    }
    if ($args{statement_like}) {
        push @where, 'statement LIKE ?';
        push @bind, "%$args{statement_like}%";
    }

    my $sql = 'SELECT * FROM wm_beliefs';
    $sql .= ' WHERE ' . join(' AND ', @where);
    $sql .= ' ORDER BY confidence DESC';
    $sql .= " LIMIT $args{limit}" if $args{limit};

    my $rows = $self->{dbh}->selectall_arrayref($sql, { Slice => {} }, @bind);
    for my $r (@$rows) {
        $r->{evidence} = jdecode($r->{evidence} // '[]');
    }
    return $rows;
}

sub supersede_belief {
    my ($self, $old_id, %new_args) = @_;
    my $new_id = $self->believe(%new_args);
    $self->{dbh}->do(
        'UPDATE wm_beliefs SET superseded_by = ? WHERE id = ?',
        undef, $new_id, $old_id,
    );
    return $new_id;
}

# Temporal range queries for beliefs

sub beliefs_temporal {
    my ($self, %args) = @_;
    my @where;
    my @bind;

    if (defined $args{min_confidence}) {
        push @where, 'confidence >= ?';
        push @bind, $args{min_confidence};
    }
    if (defined $args{source}) {
        push @where, 'source = ?';
        push @bind, $args{source};
    }
    if ($args{statement_like}) {
        push @where, 'statement LIKE ?';
        push @bind, "%$args{statement_like}%";
    }

    # created_at >= from_time (belief existed at or after from_time)
    if (defined $args{from_time}) {
        push @where, 'created_at >= ?';
        push @bind, $args{from_time};
    }

    # created_at <= to_time (belief created before or at to_time)
    if (defined $args{to_time}) {
        push @where, 'created_at <= ?';
        push @bind, $args{to_time};
    }

    # Only current beliefs (not superseded) unless include_superseded
    if (!$args{include_superseded}) {
        if (defined $args{to_time}) {
            # At to_time: belief must exist (created_at <= to_time) and
            # either not superseded or superseded after to_time
            push @where, '(superseded_by IS NULL OR superseded_by IN (
                SELECT id FROM wm_beliefs WHERE created_at > ?
            ))';
            push @bind, $args{to_time};
        } else {
            push @where, 'superseded_by IS NULL';
        }
    }

    my $sql = 'SELECT * FROM wm_beliefs';
    $sql .= ' WHERE ' . join(' AND ', @where) if @where;
    $sql .= ' ORDER BY confidence DESC';
    $sql .= " LIMIT $args{limit}" if $args{limit};

    my $rows = $self->{dbh}->selectall_arrayref($sql, { Slice => {} }, @bind);
    for my $r (@$rows) {
        $r->{evidence} = jdecode($r->{evidence} // '[]');
    }
    return $rows;
}

sub beliefs_at_time {
    my ($self, $time, %args) = @_;
    return $self->beliefs_temporal(
        to_time          => $time,
        from_time        => $args{from_time},
        min_confidence   => $args{min_confidence},
        source           => $args{source},
        statement_like   => $args{statement_like},
        limit            => $args{limit},
    );
}

sub belief_history {
    my ($self, %args) = @_;
    my @where;
    my @bind;

    if (defined $args{min_confidence}) {
        push @where, 'confidence >= ?';
        push @bind, $args{min_confidence};
    }
    if ($args{statement_like}) {
        push @where, 'statement LIKE ?';
        push @bind, "%$args{statement_like}%";
    }

    # Include all beliefs (current and superseded)
    my $sql = 'SELECT * FROM wm_beliefs';
    $sql .= ' WHERE ' . join(' AND ', @where) if @where;
    $sql .= ' ORDER BY created_at DESC';

    my $rows = $self->{dbh}->selectall_arrayref($sql, { Slice => {} }, @bind);
    for my $r (@$rows) {
        $r->{evidence} = jdecode($r->{evidence} // '[]');
    }
    return $rows;
}

sub belief_lineage {
    my ($self, $belief_id) = @_;
    my @chain;
    my $id = $belief_id;

    while ($id) {
        my $row = $self->{dbh}->selectrow_hashref(
            'SELECT * FROM wm_beliefs WHERE id = ?', undef, $id,
        );
        last unless $row;
        $row->{evidence} = jdecode($row->{evidence} // '[]');
        push @chain, $row;
        $id = $row->{superseded_by};
    }

    return \@chain;
}

# ---------------------------------------------------------------------------
# Query helpers
# ---------------------------------------------------------------------------

sub relevant_facts {
    my ($self, $text) = @_;
    return [] unless defined $text && length $text;

    # Extract potential entity names from text (simple: capitalized words)
    my @words = $text =~ /\b([A-Z][a-z]+(?:\s+[A-Z][a-z]+)*)\b/g;
    return [] unless @words;

    my @facts;
    my %seen;
    for my $word (@words) {
        next if $seen{$word}++;
        my $entities = $self->query_entities(name => $word, limit => 1);
        for my $ent (@$entities) {
            my $facts = $self->query_facts(entity_id => $ent->{id});
            push @facts, { entity => $ent, fact => $_ } for @$facts;
        }
    }
    return \@facts;
}

sub to_context {
    my ($self, $text) = @_;
    my $facts = $self->relevant_facts($text);
    return '' unless @$facts;

    my @lines;
    for my $f (@$facts) {
        my $ent = $f->{entity};
        my $fact = $f->{fact};
        push @lines, "$ent->{name} ($ent->{type}): $fact->{predicate} = $fact->{value}";
    }

    my $beliefs = $self->query_beliefs(min_confidence => 0.7, limit => 10);
    for my $b (@$beliefs) {
        push @lines, "Belief ($b->{confidence}): $b->{statement}";
    }

    return @lines ? "World model context:\n" . join("\n", @lines) : '';
}

# ---------------------------------------------------------------------------
# FTS5 search (requires FTS5 extension)
# ---------------------------------------------------------------------------

sub has_fts { $_[0]->{has_fts} }

sub _fts_quote {
    my ($text) = @_;
    $text =~ s/"/""/g;
    return "\"$text\"";
}

sub search_entities {
    my ($self, $query, %args) = @_;
    return [] unless $self->{has_fts} && defined $query && length $query;

    my $limit = $args{limit} // 10;
    my $q = _fts_quote($query);

    my $rows = $self->{dbh}->selectall_arrayref(
        "SELECT e.*, rank FROM wm_entities_fts f
         JOIN wm_entities e ON e.rowid = f.rowid
         WHERE wm_entities_fts MATCH ?
         ORDER BY rank
         LIMIT $limit",
        { Slice => {} }, $q,
    );
    for my $r (@$rows) {
        $r->{attributes} = jdecode($r->{attributes} // '{}');
    }
    return $rows;
}

sub search_beliefs {
    my ($self, $query, %args) = @_;
    return [] unless $self->{has_fts} && defined $query && length $query;

    my $limit = $args{limit} // 10;
    my $min_conf = $args{min_confidence} // 0;
    my $q = _fts_quote($query);

    my $rows = $self->{dbh}->selectall_arrayref(
        "SELECT b.*, rank FROM wm_beliefs_fts f
         JOIN wm_beliefs b ON b.rowid = f.rowid
         WHERE wm_beliefs_fts MATCH ?
           AND b.superseded_by IS NULL
           AND b.confidence >= ?
         ORDER BY rank
         LIMIT $limit",
        { Slice => {} }, $q, $min_conf,
    );
    for my $r (@$rows) {
        $r->{evidence} = jdecode($r->{evidence} // '[]');
    }
    return $rows;
}

sub search_facts {
    my ($self, $query, %args) = @_;
    return [] unless $self->{has_fts} && defined $query && length $query;

    my $limit = $args{limit} // 10;
    my $q = _fts_quote($query);

    my $rows = $self->{dbh}->selectall_arrayref(
        "SELECT ft.id, ft.predicate, ft.value, ft.source, rank
         FROM wm_facts_fts ft
         WHERE wm_facts_fts MATCH ?
         ORDER BY rank
         LIMIT $limit",
        { Slice => {} }, $q,
    );
    for my $r (@$rows) {
        $r->{value} = jdecode($r->{value}) if $r->{value} =~ /^[\{\[]/;
    }
    return $rows;
}

sub search_all {
    my ($self, $query, %args) = @_;
    my $limit = $args{limit} // 5;

    return {
        entities => $self->search_entities($query, limit => $limit),
        beliefs  => $self->search_beliefs($query, limit => $limit),
        facts    => $self->search_facts($query, limit => $limit),
    };
}

# ---------------------------------------------------------------------------
# Internal
# ---------------------------------------------------------------------------

sub _gen_id {
    my @chars = ('a'..'z', '0'..'9');
    return join '', map { $chars[int(rand(@chars))] } 1..12;
}

1;
