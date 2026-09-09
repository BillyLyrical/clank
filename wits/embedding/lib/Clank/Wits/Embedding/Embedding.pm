# CLANK-WIT: name=Embedding
# CLANK-WIT: version=1.0.0
# CLANK-WIT: about=Semantic search via vector embeddings. Requires an embedding provider (Ollama, OpenAI).
# CLANK-WIT: usage=Input: { action: "search", query: "what causes rain", limit: 5 } Output: { results: [{ id, name, score }] }
# CLANK-WIT: hint=embedding, semantic search, vector, cosine similarity
# CLANK-WIT: author=Clank
# CLANK-WIT: license=Artistic-2.0
package Clank::Wits::Embedding::Embedding;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;

    my $store = $api->store or return;
    my $dbh = $store->dbh;

    # Schema for embeddings. Uses the world model's entity table as source.
    $dbh->do(qq{
CREATE TABLE IF NOT EXISTS wm_embeddings (
  entity_id TEXT PRIMARY KEY REFERENCES wm_entities(id) ON DELETE CASCADE,
  embedding TEXT NOT NULL,
  model TEXT,
  dimensions INTEGER,
  created_at INTEGER
)});
    $dbh->do(qq{
CREATE INDEX IF NOT EXISTS idx_wm_embeddings_model ON wm_embeddings(model)});

    # Detect available embedding provider.
    my $provider = _detect_provider();

    $api->register_tool(
        name        => 'semantic_search',
        description => 'Semantic search over world model entities using vector embeddings. Finds entities similar in meaning to the query.',
        parameters  => {
            type       => 'object',
            properties => {
                query  => { type => 'string', description => 'Search query (natural language)' },
                limit  => { type => 'integer', description => 'Max results', default => 5 },
                type   => { type => 'string', description => 'Filter by entity type' },
                min_score => { type => 'number', description => 'Minimum similarity score (0-1)', default => 0.3 },
            },
            required => ['query'],
        },
        execute => sub {
            my ($args) = @_;
            my $query = $args->{query} // '';
            my $limit = $args->{limit} // 5;
            my $type_filter = $args->{type};
            my $min_score = $args->{min_score} // 0.3;

            return { error => 'No query provided' } unless length $query;
            return { error => 'No embedding provider available. Start Ollama or configure CLAM_EMBEDDING_API.' }
                unless $provider;

            # Embed the query.
            my $query_vec = _embed($provider, $query);
            return { error => "Embedding failed: $provider->{error}" } unless $query_vec;

            # Load all embeddings from DB.
            my ($sql, @bind) = ('SELECT e.entity_id, e.embedding, e.model, en.type, en.name FROM wm_embeddings e JOIN wm_entities en ON en.id = e.entity_id');
            if ($type_filter) {
                $sql .= ' WHERE en.type = ?';
                push @bind, $type_filter;
            }
            my $rows = $dbh->selectall_arrayref($sql, { Slice => {} }, @bind);

            # Score each entity.
            my @scored;
            for my $row (@$rows) {
                my $vec = _parse_embedding($row->{embedding});
                next unless $vec;
                my $score = _cosine_sim($query_vec, $vec);
                next if $score < $min_score;
                push @scored, {
                    id    => $row->{entity_id},
                    name  => $row->{name},
                    type  => $row->{type},
                    score => $score,
                };
            }

            # Sort by score descending, return top N.
            @scored = sort { $b->{score} <=> $a->{score}} @scored[0..($limit-1 > $#scored ? $#scored : $limit-1)];

            return { results => \@scored, provider => $provider->{name}, total => scalar @scored };
        },
    );

    $api->register_tool(
        name        => 'embed_entity',
        description => 'Generate and store a vector embedding for a world model entity. Enables semantic search.',
        parameters  => {
            type       => 'object',
            properties => {
                entity_id => { type => 'string', description => 'Entity ID to embed' },
                text      => { type => 'string', description => 'Text to embed (defaults to entity name + attributes)' },
            },
            required => ['entity_id'],
        },
        execute => sub {
            my ($args) = @_;
            my $entity_id = $args->{entity_id} // '';
            my $text = $args->{text};

            return { error => 'No entity_id provided' } unless length $entity_id;
            return { error => 'No embedding provider available' } unless $provider;

            # Fetch entity if no text provided.
            unless (defined $text && length $text) {
                my $ent = $dbh->selectrow_hashref(
                    'SELECT * FROM wm_entities WHERE id = ?', undef, $entity_id);
                return { error => "Entity not found: $entity_id" } unless $ent;

                my $attrs = $ent->{attributes} ? eval { JSON::PP::decode_json($ent->{attributes}) } : {};
                $text = ($ent->{name} // '') . ' ' . join(' ', map { "$_: $attrs->{$_}" } sort keys %$attrs);
                $text =~ s/^\s+|\s+$//g;
                return { error => 'Entity has no name or attributes to embed' } unless length $text;
            }

            my $vec = _embed($provider, $text);
            return { error => "Embedding failed: $provider->{error}" } unless $vec;

            my $now = int(time() * 1000);
            $dbh->prepare(
                'INSERT INTO wm_embeddings (entity_id,embedding,model,dimensions,created_at) VALUES (?,?,?,?,?) ON CONFLICT(entity_id) DO UPDATE SET embedding=excluded.embedding,model=excluded.model,dimensions=excluded.dimensions,created_at=excluded.created_at'
            )->execute($entity_id, _vec_to_csv($vec), $provider->{model}, scalar @$vec, $now);

            return { entity_id => $entity_id, dimensions => scalar @$vec, model => $provider->{model} };
        },
    );

    $api->register_tool(
        name        => 'embed_batch',
        description => 'Batch-embed all world model entities that lack embeddings.',
        parameters  => {
            type       => 'object',
            properties => {
                limit => { type => 'integer', description => 'Max entities to embed', default => 50 },
            },
        },
        execute => sub {
            my ($args) = @_;
            my $limit = $args->{limit} // 50;
            return { error => 'No embedding provider available' } unless $provider;

            # Find entities without embeddings.
            my $entities = $dbh->selectall_arrayref(
                'SELECT e.id, e.name, e.attributes FROM wm_entities e LEFT JOIN wm_embeddings em ON em.entity_id = e.id WHERE em.entity_id IS NULL LIMIT ?',
                { Slice => {} }, $limit);

            my $embedded = 0;
            my @errors;
            for my $ent (@$entities) {
                my $attrs = $ent->{attributes} ? eval { JSON::PP::decode_json($ent->{attributes}) } : {};
                my $text = ($ent->{name} // '') . ' ' . join(' ', map { "$_: $attrs->{$_}" } sort keys %$attrs);
                $text =~ s/^\s+|\s+$//g;
                next unless length $text;

                my $vec = _embed($provider, $text);
                unless ($vec) {
                    push @errors, "$ent->{id}: $provider->{error}";
                    next;
                }

                my $now = int(time() * 1000);
                $dbh->prepare(
                    'INSERT INTO wm_embeddings (entity_id,embedding,model,dimensions,created_at) VALUES (?,?,?,?,?) ON CONFLICT(entity_id) DO UPDATE SET embedding=excluded.embedding,model=excluded.model,dimensions=excluded.dimensions,created_at=excluded.created_at'
                )->execute($ent->{id}, _vec_to_csv($vec), $provider->{model}, scalar @$vec, $now);
                $embedded++;
            }

            return { embedded => $embedded, errors => \@errors, remaining => $limit - $embedded };
        },
    );
}

# === EMBEDDING PROVIDERS ===

sub _detect_provider {
    # Try Ollama first (local, free).
    my $base_url = $ENV{CLAM_OLLAMA_URL} // 'http://localhost:11434';
    if (_check_url("$base_url/api/tags")) {
        my $model = $ENV{CLAM_EMBEDDING_MODEL} // 'nomic-embed-text';
        return { name => 'ollama', base_url => $base_url, model => $model };
    }

    # Try OpenAI-compatible endpoint.
    if ($ENV{CLAM_EMBEDDING_API} && $ENV{CLAM_EMBEDDING_KEY}) {
        return {
            name     => 'openai',
            base_url => $ENV{CLAM_EMBEDDING_API},
            model    => $ENV{CLAM_EMBEDDING_MODEL} // 'text-embedding-3-small',
            api_key  => $ENV{CLAM_EMBEDDING_KEY},
        };
    }

    return undef;
}

sub _check_url {
    my ($url) = @_;
    eval {
        require HTTP::Tiny;
        my $http = HTTP::Tiny->new(timeout => 2);
        my $res = $http->get($url);
        return $res->{success};
    };
    return 0;
}

sub _embed {
    my ($provider, $text) = @_;

    if ($provider->{name} eq 'ollama') {
        return _embed_ollama($provider, $text);
    } elsif ($provider->{name} eq 'openai') {
        return _embed_openai($provider, $text);
    }

    return undef;
}

sub _embed_ollama {
    my ($provider, $text) = @_;
    require HTTP::Tiny;
    require JSON::PP;

    my $url = "$provider->{base_url}/api/embeddings";
    my $payload = JSON::PP::encode_json({
        model  => $provider->{model},
        prompt => $text,
    });

    my $http = HTTP::Tiny->new(timeout => 30);
    my $res = $http->request('POST', $url, {
        headers => { 'Content-Type' => 'application/json' },
        content => $payload,
    });

    unless ($res->{success}) {
        $provider->{error} = "Ollama HTTP $res->{status}: $res->{reason}";
        return undef;
    }

    my $data = eval { JSON::PP::decode_json($res->{content}) };
    unless (ref $data eq 'HASH' && ref $data->{embedding} eq 'ARRAY') {
        $provider->{error} = 'Ollama returned no embedding';
        return undef;
    }

    return $data->{embedding};
}

sub _embed_openai {
    my ($provider, $text) = @_;
    require HTTP::Tiny;
    require JSON::PP;

    my $url = "$provider->{base_url}/v1/embeddings";
    my $payload = JSON::PP::encode_json({
        model => $provider->{model},
        input => $text,
    });

    my $http = HTTP::Tiny->new(timeout => 30);
    my $res = $http->request('POST', $url, {
        headers => {
            'Content-Type'  => 'application/json',
            'Authorization' => "Bearer $provider->{api_key}",
        },
        content => $payload,
    });

    unless ($res->{success}) {
        $provider->{error} = "OpenAI HTTP $res->{status}: $res->{reason}";
        return undef;
    }

    my $data = eval { JSON::PP::decode_json($res->{content}) };
    unless (ref $data eq 'HASH' && ref $data->{data} eq 'ARRAY') {
        $provider->{error} = 'OpenAI returned no embedding';
        return undef;
    }

    return $data->{data}[0]{embedding};
}

# === VECTOR MATH ===

sub _cosine_sim {
    my ($a, $b) = @_;
    return 0 unless @$a && @$b && @$a == @$b;
    my ($dot, $na, $nb) = (0, 0, 0);
    for my $i (0..$#$a) {
        $dot += $a->[$i] * $b->[$i];
        $na  += $a->[$i] ** 2;
        $nb  += $b->[$i] ** 2;
    }
    my $denom = sqrt($na) * sqrt($nb);
    return $denom > 0 ? $dot / $denom : 0;
}

sub _vec_to_csv {
    my ($vec) = @_;
    return join(',', @$vec);
}

sub _parse_embedding {
    my ($csv) = @_;
    return undef unless defined $csv && length $csv;
    return [ split /,/, $csv ];
}

1;
