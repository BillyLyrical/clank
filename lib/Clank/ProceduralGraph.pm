# Procedural graph: directed attributed graph of procedural knowledge.
# Organizes (procedure, relation, procedure) triplets for what-to-do questions.
# Extends Clank::Store with pg_nodes, pg_edges, and evolution tables.
package Clank::ProceduralGraph;
use strict;
use warnings;
use Clank::Util qw(uuid4 now_ms jencode jdecode);

sub new {
    my ($class, %args) = @_;
    my $store = $args{store} or die "Clank::ProceduralGraph requires store";
    my $self = bless { store => $store, dbh => $store->dbh }, $class;
    $self->_init_schema;
    return $self;
}

sub dbh { $_[0]->{dbh} }

# ---------------------------------------------------------------------------
# Schema
# ---------------------------------------------------------------------------

sub _init_schema {
    my ($self) = @_;
    my $db = $self->{dbh};

    $db->do(qq{
CREATE TABLE IF NOT EXISTS pg_nodes (
    id          TEXT PRIMARY KEY,
    label       TEXT NOT NULL,
    description TEXT,
    node_type   TEXT DEFAULT 'procedure',
    attributes  TEXT,
    created_at  INTEGER NOT NULL,
    updated_at  INTEGER NOT NULL
)});

    $db->do(qq{
CREATE TABLE IF NOT EXISTS pg_edges (
    id          TEXT PRIMARY KEY,
    source_id   TEXT NOT NULL REFERENCES pg_nodes(id),
    target_id   TEXT NOT NULL REFERENCES pg_nodes(id),
    relation    TEXT NOT NULL,
    attributes  TEXT,
    weight      REAL DEFAULT 1.0,
    enabled     INTEGER DEFAULT 1,
    created_at  INTEGER NOT NULL,
    updated_at  INTEGER NOT NULL
)});
    $db->do(qq{CREATE INDEX IF NOT EXISTS idx_pg_edges_source ON pg_edges(source_id)});
    $db->do(qq{CREATE INDEX IF NOT EXISTS idx_pg_edges_target ON pg_edges(target_id)});

    $db->do(qq{
CREATE TABLE IF NOT EXISTS pg_evolution_log (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    round       INTEGER NOT NULL,
    mutation    TEXT NOT NULL,
    candidate   TEXT NOT NULL,
    train_score REAL,
    val_score   REAL,
    committed   INTEGER NOT NULL,
    reason      TEXT,
    created_at  INTEGER NOT NULL
)});
    $db->do(qq{CREATE INDEX IF NOT EXISTS idx_pg_evolution_round ON pg_evolution_log(round)});

    $db->do(qq{
CREATE TABLE IF NOT EXISTS pg_rejections (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    round       INTEGER NOT NULL,
    mutation    TEXT NOT NULL,
    val_score   REAL,
    baseline    REAL,
    context     TEXT,
    created_at  INTEGER NOT NULL
)});
}

# ---------------------------------------------------------------------------
# Node operations
# ---------------------------------------------------------------------------

sub add_node {
    my ($self, %args) = @_;
    my $id = $args{id} || _gen_id();
    my $now = now_ms();
    my $attrs = ref $args{attributes} eq 'HASH' ? jencode($args{attributes}) : ($args{attributes} // '{}');

    $self->{dbh}->do(
        'INSERT OR REPLACE INTO pg_nodes (id, label, description, node_type, attributes, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, COALESCE((SELECT created_at FROM pg_nodes WHERE id = ?), ?), ?)',
        undef, $id, $args{label}, $args{description}, $args{node_type} // 'procedure', $attrs, $id, $now, $now,
    );
    return $id;
}

sub get_node {
    my ($self, $id) = @_;
    my $row = $self->{dbh}->selectrow_hashref(
        'SELECT * FROM pg_nodes WHERE id = ?', undef, $id,
    );
    return undef unless $row;
    $row->{attributes} = jdecode($row->{attributes} // '{}');
    return $row;
}

sub update_node {
    my ($self, $id, %args) = @_;
    my $now = now_ms();
    my @sets;
    my @bind;

    for my $key (qw(label description node_type)) {
        if (exists $args{$key}) {
            push @sets, "$key = ?";
            push @bind, $args{$key};
        }
    }
    if (exists $args{attributes}) {
        push @sets, 'attributes = ?';
        push @bind, ref $args{attributes} eq 'HASH' ? jencode($args{attributes}) : $args{attributes};
    }

    return 0 unless @sets;
    push @sets, 'updated_at = ?';
    push @bind, $now, $id;

    $self->{dbh}->do(
        "UPDATE pg_nodes SET " . join(', ', @sets) . " WHERE id = ?",
        undef, @bind,
    );
    return $self->{dbh}->rows;
}

sub delete_node {
    my ($self, $id) = @_;
    $self->{dbh}->do('UPDATE pg_edges SET enabled = 0 WHERE source_id = ? OR target_id = ?', undef, $id, $id);
    $self->{dbh}->do('DELETE FROM pg_nodes WHERE id = ?', undef, $id);
    return $self->{dbh}->rows;
}

sub all_nodes {
    my ($self) = @_;
    my $rows = $self->{dbh}->selectall_arrayref('SELECT * FROM pg_nodes ORDER BY label', { Slice => {} });
    for my $r (@$rows) {
        $r->{attributes} = jdecode($r->{attributes} // '{}');
    }
    return $rows;
}

# ---------------------------------------------------------------------------
# Edge operations
# ---------------------------------------------------------------------------

sub add_edge {
    my ($self, %args) = @_;
    my $src = $args{source_id} or die "add_edge requires source_id";
    my $tgt = $args{target_id} or die "add_edge requires target_id";
    my $rel = $args{relation}  or die "add_edge requires relation";

    die "source node '$src' does not exist" unless $self->get_node($src);
    die "target node '$tgt' does not exist" unless $self->get_node($tgt);

    my $id = $args{id} || _gen_id();
    my $now = now_ms();
    my $attrs = ref $args{attributes} eq 'HASH' ? jencode($args{attributes}) : ($args{attributes} // '{}');
    my $weight = $args{weight} // 1.0;

    $self->{dbh}->do(
        'INSERT OR REPLACE INTO pg_edges (id, source_id, target_id, relation, attributes, weight, enabled, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, 1, COALESCE((SELECT created_at FROM pg_edges WHERE id = ?), ?), ?)',
        undef, $id, $src, $tgt, $rel, $attrs, $weight, $id, $now, $now,
    );
    return $id;
}

sub get_edge {
    my ($self, $id) = @_;
    my $row = $self->{dbh}->selectrow_hashref(
        'SELECT * FROM pg_edges WHERE id = ?', undef, $id,
    );
    return undef unless $row;
    $row->{attributes} = jdecode($row->{attributes} // '{}');
    return $row;
}

sub update_edge {
    my ($self, $id, %args) = @_;
    my $now = now_ms();
    my @sets;
    my @bind;

    for my $key (qw(relation weight)) {
        if (exists $args{$key}) {
            push @sets, "$key = ?";
            push @bind, $args{$key};
        }
    }
    if (exists $args{attributes}) {
        push @sets, 'attributes = ?';
        push @bind, ref $args{attributes} eq 'HASH' ? jencode($args{attributes}) : $args{attributes};
    }
    if (exists $args{enabled}) {
        push @sets, 'enabled = ?';
        push @bind, $args{enabled} ? 1 : 0;
    }

    return 0 unless @sets;
    push @sets, 'updated_at = ?';
    push @bind, $now, $id;

    $self->{dbh}->do(
        "UPDATE pg_edges SET " . join(', ', @sets) . " WHERE id = ?",
        undef, @bind,
    );
    return $self->{dbh}->rows;
}

sub disable_edge {
    my ($self, $id) = @_;
    return $self->update_edge($id, enabled => 0);
}

sub enable_edge {
    my ($self, $id) = @_;
    return $self->update_edge($id, enabled => 1);
}

sub delete_edge {
    my ($self, $id) = @_;
    $self->{dbh}->do('DELETE FROM pg_edges WHERE id = ?', undef, $id);
    return $self->{dbh}->rows;
}

sub all_edges {
    my ($self) = @_;
    my $rows = $self->{dbh}->selectall_arrayref(
        'SELECT * FROM pg_edges WHERE enabled = 1 ORDER BY source_id, target_id',
        { Slice => {} },
    );
    for my $r (@$rows) {
        $r->{attributes} = jdecode($r->{attributes} // '{}');
    }
    return $rows;
}

# ---------------------------------------------------------------------------
# Graph queries
# ---------------------------------------------------------------------------

sub outgoing {
    my ($self, $node_id) = @_;
    my $rows = $self->{dbh}->selectall_arrayref(
        'SELECT * FROM pg_edges WHERE source_id = ? AND enabled = 1 ORDER BY target_id',
        { Slice => {} }, $node_id,
    );
    for my $r (@$rows) {
        $r->{attributes} = jdecode($r->{attributes} // '{}');
    }
    return $rows;
}

sub incoming {
    my ($self, $node_id) = @_;
    my $rows = $self->{dbh}->selectall_arrayref(
        'SELECT * FROM pg_edges WHERE target_id = ? AND enabled = 1 ORDER BY source_id',
        { Slice => {} }, $node_id,
    );
    for my $r (@$rows) {
        $r->{attributes} = jdecode($r->{attributes} // '{}');
    }
    return $rows;
}

# Extract h-hop directed neighborhood of a node.
# Returns { node => {...}, edges => [...] } with edges enriched with target node info.
sub neighborhood {
    my ($self, $node_id, $hops) = @_;
    $hops //= 2;

    my $node = $self->get_node($node_id);
    return undef unless $node;

    my %visited;
    my @edges;
    my @queue = ($node_id);

    for my $depth (0 .. $hops - 1) {
        my @next;
        for my $nid (@queue) {
            next if $visited{$nid}++;
            my $out = $self->outgoing($nid);
            for my $e (@$out) {
                my $target = $self->get_node($e->{target_id});
                push @edges, {
                    id         => $e->{id},
                    source_id  => $e->{source_id},
                    target_id  => $e->{target_id},
                    relation   => $e->{relation},
                    attributes => $e->{attributes},
                    target_label => $target->{label} // $e->{target_id},
                };
                push @next, $e->{target_id} unless $visited{$e->{target_id}};
            }
        }
        @queue = @next;
    }

    return { node => $node, edges => \@edges };
}

# ---------------------------------------------------------------------------
# Trajectory localization
# ---------------------------------------------------------------------------

# Match the agent's last action to the nearest node in the graph.
# Strategy: exact match on node label/id, then fuzzy substring match.
sub localize {
    my ($self, $last_action) = @_;
    return undef unless defined $last_action && length $last_action;

    my $nodes = $self->all_nodes;
    return undef unless @$nodes;

    # Exact match: action text matches a node label or id (case-insensitive)
    my $la = lc($last_action);
    for my $n (@$nodes) {
        return $n->{id} if lc($n->{id}) eq $la;
        return $n->{id} if defined $n->{label} && lc($n->{label}) eq $la;
    }

    # Fuzzy: action text contains a node label or id
    for my $n (@$nodes) {
        return $n->{id} if index($la, lc($n->{id})) >= 0;
        return $n->{id} if defined $n->{label} && index($la, lc($n->{label})) >= 0;
    }

    # Reverse fuzzy: node label/id is a substring of the action
    for my $n (@$nodes) {
        my $nid = lc($n->{id});
        return $n->{id} if length($nid) > 2 && index($nid, $la) >= 0;
        if (defined $n->{label}) {
            my $nl = lc($n->{label});
            return $n->{id} if length($nl) > 2 && index($nl, $la) >= 0;
        }
    }

    return undef;
}

# ---------------------------------------------------------------------------
# Subgraph extraction for guidance
# ---------------------------------------------------------------------------

# Extract a guidance subgraph centered on a node.
# Returns arrayref of edges with target node labels, suitable for formatting.
sub extract_guidance_subgraph {
    my ($self, $node_id, $hops) = @_;
    $hops //= 2;
    my $nh = $self->neighborhood($node_id, $hops);
    return undef unless $nh;
    return $nh->{edges};
}

# ---------------------------------------------------------------------------
# Serialization
# ---------------------------------------------------------------------------

sub to_hash {
    my ($self) = @_;
    my $nodes = $self->all_nodes;
    my $edges = $self->all_edges;
    return { nodes => $nodes, edges => $edges };
}

sub from_hash {
    my ($self, $data) = @_;
    my $dbh = $self->{dbh};

    $dbh->begin_work;
    eval {
        $dbh->do('DELETE FROM pg_edges');
        $dbh->do('DELETE FROM pg_nodes');

        for my $n (@{$data->{nodes} // []}) {
            $self->add_node(
                id          => $n->{id},
                label       => $n->{label},
                description => $n->{description},
                node_type   => $n->{node_type},
                attributes  => $n->{attributes},
            );
        }
        for my $e (@{$data->{edges} // []}) {
            $self->add_edge(
                id         => $e->{id},
                source_id  => $e->{source_id},
                target_id  => $e->{target_id},
                relation   => $e->{relation},
                attributes => $e->{attributes},
                weight     => $e->{weight},
            );
        }
        $dbh->commit;
    };
    if ($@) {
        $dbh->rollback;
        die "from_hash failed: $@";
    }
    return scalar @{$data->{nodes} // []};
}

sub clear {
    my ($self) = @_;
    $self->{dbh}->do('DELETE FROM pg_edges');
    $self->{dbh}->do('DELETE FROM pg_nodes');
    $self->{dbh}->do('DELETE FROM pg_evolution_log');
    $self->{dbh}->do('DELETE FROM pg_rejections');
    return 1;
}

# ---------------------------------------------------------------------------
# Statistics
# ---------------------------------------------------------------------------

sub stats {
    my ($self) = @_;
    my $dbh = $self->{dbh};
    my ($node_count) = $dbh->selectrow_array('SELECT COUNT(*) FROM pg_nodes');
    my ($edge_count) = $dbh->selectrow_array('SELECT COUNT(*) FROM pg_edges WHERE enabled = 1');
    my ($disabled)   = $dbh->selectrow_array('SELECT COUNT(*) FROM pg_edges WHERE enabled = 0');
    my ($evol_rounds) = $dbh->selectrow_array('SELECT COALESCE(MAX(round), 0) FROM pg_evolution_log');
    return {
        nodes         => $node_count,
        edges         => $edge_count,
        disabled_edges => $disabled,
        evolution_rounds => $evol_rounds,
    };
}

# ---------------------------------------------------------------------------
# Private
# ---------------------------------------------------------------------------

sub _gen_id {
    my @chars = ('a'..'z', '0'..'9');
    return join '', map { $chars[int(rand(@chars))] } 1..12;
}

1;
