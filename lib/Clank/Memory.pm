# Clank::Memory — unified memory documents (ECC memory.v1 compatible).
#
# Typed, scoped, status-tracked knowledge documents. Complementary to
# WorldModel (entities/relations/facts/beliefs) for durable structured
# knowledge like lessons, runbooks, decisions, and handoffs.
#
# Schema compatible with ECC memory.schema.json (ecc.memory.v1).
package Clank::Memory;
use strict;
use warnings;
use Clank::Util qw(now_ms uuid4 jencode jdecode);

my @VALID_KINDS     = qw(context decision fact handoff lesson note preference runbook);
my @VALID_SCOPES    = qw(project team user);
my @VALID_STATUSES  = qw(active rejected superseded);

sub new {
    my ($class, %args) = @_;
    my $store = $args{store} or die "Clank::Memory requires store";
    my $self = bless {
        store => $store,
        dbh   => $store->dbh,
    }, $class;
    $self->_init_schema;
    return $self;
}

sub _dbh { $_[0]->{dbh} }

sub _init_schema {
    my ($self) = @_;
    $self->_dbh->do(qq{
CREATE TABLE IF NOT EXISTS memory_documents (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  kind TEXT NOT NULL DEFAULT 'note',
  scope TEXT NOT NULL DEFAULT 'project',
  status TEXT NOT NULL DEFAULT 'active',
  tags TEXT DEFAULT '[]',
  links TEXT DEFAULT '[]',
  body TEXT NOT NULL,
  project_id TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
)});
    $self->_dbh->do(qq{
CREATE INDEX IF NOT EXISTS idx_memory_kind ON memory_documents(kind)});
    $self->_dbh->do(qq{
CREATE INDEX IF NOT EXISTS idx_memory_scope ON memory_documents(scope)});
    $self->_dbh->do(qq{
CREATE INDEX IF NOT EXISTS idx_memory_status ON memory_documents(status)});
    $self->_dbh->do(qq{
CREATE INDEX IF NOT EXISTS idx_memory_project ON memory_documents(project_id)});

    # FTS5 for full-text search on body and title.
    eval {
        $self->_dbh->do(qq{
CREATE VIRTUAL TABLE IF NOT EXISTS memory_fts USING fts5(id, title, body, content=memory_documents, content_rowid=rowid)});
    };
}

# === BUS INTEGRATION ===

sub register {
    my ($self, $api) = @_;
    $self->{api} = $api;

    $api->on('context_knowledge_request', sub { $self->_on_knowledge_request(@_) });

    $api->register_command('memory',
        description => 'memory: list|search|get <id>|stats',
        handler => sub { $self->_cmd_memory(@_) });

    return $self;
}

sub _on_knowledge_request {
    my ($self, $ev) = @_;
    my $prompt = $ev->{payload}{prompt} // '';
    return unless length $prompt;

    my $docs = $self->search(query => $prompt, limit => 5, status => 'active');
    return unless @$docs;

    my @facts;
    for my $doc (@$docs) {
        push @facts, {
            type => "memory_$doc->{kind}",
            text => sprintf("[%s] %s: %s",
                $doc->{kind}, $doc->{title},
                substr($doc->{body}, 0, 200)),
        };
    }
    return { facts => \@facts } if @facts;
    return undef;
}

# === CRUD ===

sub create {
    my ($self, %args) = @_;
    my $id = $args{id} // ('mem_' . uuid4());
    my $now = now_ms();

    my $kind   = $args{kind}   // 'note';
    my $scope  = $args{scope}  // 'project';
    my $status = $args{status} // 'active';

    unless (grep { $_ eq $kind } @VALID_KINDS) {
        return { error => "Invalid kind: $kind. Valid: @VALID_KINDS" };
    }
    unless (grep { $_ eq $scope } @VALID_SCOPES) {
        return { error => "Invalid scope: $scope. Valid: @VALID_SCOPES" };
    }
    unless (grep { $_ eq $status } @VALID_STATUSES) {
        return { error => "Invalid status: $status. Valid: @VALID_STATUSES" };
    }

    my $tags  = ref $args{tags} eq 'ARRAY' ? jencode($args{tags}) : '[]';
    my $links = ref $args{links} eq 'ARRAY' ? jencode($args{links}) : '[]';

    eval {
        $self->_dbh->prepare(
            'INSERT INTO memory_documents (id, title, kind, scope, status, tags, links, body, project_id, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?)'
        )->execute(
            $id, $args{title}, $kind, $scope, $status,
            $tags, $links, $args{body} // '',
            $args{project_id}, $now, $now,
        );
    };
    return { error => $@ } if $@;

    # Update FTS index.
    eval {
        $self->_dbh->do(
            'INSERT INTO memory_fts(id, title, body) VALUES (?,?,?)',
            undef, $id, $args{title} // '', $args{body} // '');
    };

    return { id => $id, created_at => $now };
}

sub get {
    my ($self, $id) = @_;
    my $row = $self->_dbh->selectrow_hashref(
        'SELECT * FROM memory_documents WHERE id = ?', undef, $id);
    return undef unless $row;
    $row->{tags}  = eval { jdecode($row->{tags}) }  // [];
    $row->{links} = eval { jdecode($row->{links}) } // [];
    return $row;
}

sub update {
    my ($self, $id, %args) = @_;
    my $doc = $self->get($id);
    return { error => "Document $id not found" } unless $doc;

    my $now = now_ms();
    my @sets = ('updated_at = ?');
    my @bind = ($now);

    for my $field (qw(title kind scope status body project_id)) {
        if (defined $args{$field}) {
            push @sets, "$field = ?";
            push @bind, $args{$field};
        }
    }
    if (defined $args{tags}) {
        push @sets, 'tags = ?';
        push @bind, ref $args{tags} eq 'ARRAY' ? jencode($args{tags}) : $args{tags};
    }
    if (defined $args{links}) {
        push @sets, 'links = ?';
        push @bind, ref $args{links} eq 'ARRAY' ? jencode($args{links}) : $args{links};
    }

    push @bind, $id;
    $self->_dbh->do(
        'UPDATE memory_documents SET ' . join(', ', @sets) . ' WHERE id = ?',
        undef, @bind);

    return { id => $id, updated_at => $now };
}

sub delete {
    my ($self, $id) = @_;
    $self->_dbh->do('DELETE FROM memory_documents WHERE id = ?', undef, $id);
    eval { $self->_dbh->do('DELETE FROM memory_fts WHERE id = ?', undef, $id) };
    return { id => $id, deleted => 1 };
}

sub list {
    my ($self, %args) = @_;
    my @where = ('1=1');
    my @bind;

    if ($args{kind}) {
        push @where, 'kind = ?';
        push @bind, $args{kind};
    }
    if ($args{scope}) {
        push @where, 'scope = ?';
        push @bind, $args{scope};
    }
    if ($args{status}) {
        push @where, 'status = ?';
        push @bind, $args{status};
    }
    if ($args{project_id}) {
        push @where, 'project_id = ?';
        push @bind, $args{project_id};
    }

    my $limit = $args{limit} // 50;
    my $sql = 'SELECT * FROM memory_documents WHERE '
            . join(' AND ', @where)
            . ' ORDER BY updated_at DESC LIMIT ?';
    push @bind, $limit;

    my $rows = $self->_dbh->selectall_arrayref($sql, { Slice => {} }, @bind);
    for my $r (@$rows) {
        $r->{tags}  = eval { jdecode($r->{tags}) }  // [];
        $r->{links} = eval { jdecode($r->{links}) } // [];
    }
    return $rows;
}

sub search {
    my ($self, %args) = @_;
    my $query = $args{query} // '';
    my $limit = $args{limit} // 10;

    return [] unless length $query;

    my $fts_rows = eval {
        $self->_dbh->selectall_arrayref(
            'SELECT id FROM memory_fts WHERE memory_fts MATCH ? ORDER BY rank LIMIT ?',
            { Slice => {} }, $query, $limit);
    };

    my @ids = map { $_->{id} } @{ $fts_rows // [] };
    return [] unless @ids;

    my $placeholders = join(',', ('?') x @ids);
    my @bind = (@ids);
    if ($args{status}) {
        my $rows = $self->_dbh->selectall_arrayref(
            "SELECT * FROM memory_documents WHERE id IN ($placeholders) AND status = ? ORDER BY updated_at DESC",
            { Slice => {} }, @bind, $args{status});
        for my $r (@$rows) {
            $r->{tags}  = eval { jdecode($r->{tags}) }  // [];
            $r->{links} = eval { jdecode($r->{links}) } // [];
        }
        return $rows;
    }

    my $rows = $self->_dbh->selectall_arrayref(
        "SELECT * FROM memory_documents WHERE id IN ($placeholders) ORDER BY updated_at DESC",
        { Slice => {} }, @bind);
    for my $r (@$rows) {
        $r->{tags}  = eval { jdecode($r->{tags}) }  // [];
        $r->{links} = eval { jdecode($r->{links}) } // [];
    }
    return $rows;
}

sub stats {
    my ($self) = @_;
    my $dbh = $self->_dbh;
    return {
        total    => $dbh->selectrow_array('SELECT COUNT(*) FROM memory_documents'),
        active   => $dbh->selectrow_array("SELECT COUNT(*) FROM memory_documents WHERE status = 'active'"),
        by_kind  => { map { $_->[0] => $_->[1] } @{
            $dbh->selectall_arrayref('SELECT kind, COUNT(*) FROM memory_documents GROUP BY kind')
        }},
        by_scope => { map { $_->[0] => $_->[1] } @{
            $dbh->selectall_arrayref('SELECT scope, COUNT(*) FROM memory_documents GROUP BY scope')
        }},
    };
}

# === CLI ===

sub _cmd_memory {
    my ($self, $ctx, $args) = @_;
    my ($subcmd, @rest) = split /\s+/, ($args // '');
    $subcmd //= 'list';

    if ($subcmd eq 'list') {
        my $kind = $rest[0];
        my $docs = $self->list($kind ? (kind => $kind) : (), limit => 20);
        my $out = "Memory documents (" . scalar @$docs . "):\n";
        for my $d (@$docs) {
            $out .= sprintf("  [%s] %s (%s) — %s\n",
                $d->{kind}, $d->{title}, $d->{scope}, $d->{status});
        }
        $out .= "  (none)\n" unless @$docs;
        return $out;
    }
    elsif ($subcmd eq 'search') {
        my $query = join(' ', @rest);
        return "Usage: /memory search <query>\n" unless $query;
        my $docs = $self->search(query => $query, limit => 5);
        my $out = "Search results for '$query':\n";
        for my $d (@$docs) {
            $out .= sprintf("  [%s] %s\n", $d->{kind}, $d->{title});
        }
        $out .= "  (none)\n" unless @$docs;
        return $out;
    }
    elsif ($subcmd eq 'get') {
        my $id = $rest[0];
        return "Usage: /memory get <id>\n" unless $id;
        my $doc = $self->get($id);
        return "Document $id not found.\n" unless $doc;
        return sprintf("[%s] %s\nScope: %s | Status: %s\n\n%s\n",
            $doc->{kind}, $doc->{title}, $doc->{scope}, $doc->{status}, $doc->{body});
    }
    elsif ($subcmd eq 'stats') {
        my $s = $self->stats;
        my $out = "Memory stats:\n";
        $out .= "  total: $s->{total} (active: $s->{active})\n";
        $out .= "  by kind: " . join(', ', map { "$_=$s->{by_kind}{$_}" } sort keys %{$s->{by_kind}}) . "\n";
        $out .= "  by scope: " . join(', ', map { "$_=$s->{by_scope}{$_}" } sort keys %{$s->{by_scope}}) . "\n";
        return $out;
    }

    return "Usage: /memory list|search|get|stats\n";
}

1;
