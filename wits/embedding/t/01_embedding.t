#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use lib "$FindBin::Bin/../lib";

use Clam::Store;
use Clam::WorldModel;

# Test the pure Perl math functions directly.
# Real embedding tests require Ollama/OpenAI — run manually.

my $store = Clam::Store->new(db => ':memory:');
my $wm = Clam::WorldModel->new(store => $store);

# Create the embeddings table (normally done by the wit's register function).
$store->dbh->do(qq{
CREATE TABLE IF NOT EXISTS wm_embeddings (
  entity_id TEXT PRIMARY KEY REFERENCES wm_entities(id) ON DELETE CASCADE,
  embedding TEXT NOT NULL,
  model TEXT,
  dimensions INTEGER,
  created_at INTEGER
)});

# === Test 1: Schema creation ===

subtest 'Schema creates wm_embeddings table' => sub {
    my $dbh = $store->dbh;
    my $info = $dbh->selectall_arrayref("PRAGMA table_info(wm_embeddings)");
    ok(scalar @$info > 0, 'wm_embeddings table exists');
};

# === Test 2: Cosine similarity ===

subtest 'Cosine similarity' => sub {
    require Clam::Wits::Embedding::Embedding;

    # Identical vectors = 1.0
    my $sim = Clam::Wits::Embedding::Embedding::_cosine_sim([1, 0, 0], [1, 0, 0]);
    is($sim, 1.0, 'identical vectors');

    # Orthogonal vectors = 0.0
    $sim = Clam::Wits::Embedding::Embedding::_cosine_sim([1, 0, 0], [0, 1, 0]);
    ok(abs($sim) < 1e-10, 'orthogonal vectors');

    # Opposite vectors = -1.0
    $sim = Clam::Wits::Embedding::Embedding::_cosine_sim([1, 0], [-1, 0]);
    ok(abs($sim + 1) < 1e-10, 'opposite vectors');

    # Similar vectors = high score
    $sim = Clam::Wits::Embedding::Embedding::_cosine_sim([1, 2, 3], [1, 2, 3.1]);
    ok($sim > 0.99, 'similar vectors score high');

    # Empty vectors = 0
    $sim = Clam::Wits::Embedding::Embedding::_cosine_sim([], []);
    is($sim, 0, 'empty vectors');
};

# === Test 3: CSV encoding/parsing ===

subtest 'Vector CSV round-trip' => sub {
    require Clam::Wits::Embedding::Embedding;

    my $vec = [0.1, 0.2, -0.3, 0.456789];
    my $csv = Clam::Wits::Embedding::Embedding::_vec_to_csv($vec);
    is($csv, '0.1,0.2,-0.3,0.456789', 'CSV encoding');

    my $parsed = Clam::Wits::Embedding::Embedding::_parse_embedding($csv);
    is_deeply($parsed, $vec, 'CSV round-trip');

    is(Clam::Wits::Embedding::Embedding::_parse_embedding(undef), undef, 'undef input');
    is(Clam::Wits::Embedding::Embedding::_parse_embedding(''), undef, 'empty input');
};

# === Test 4: Provider detection ===

subtest 'Provider detection' => sub {
    require Clam::Wits::Embedding::Embedding;

    # With no env vars, should return undef (no provider).
    local $ENV{CLAM_OLLAMA_URL} = 'http://localhost:99999';   # non-existent
    local $ENV{CLAM_EMBEDDING_API} = undef;
    local $ENV{CLAM_EMBEDDING_KEY} = undef;

    my $p = Clam::Wits::Embedding::Embedding::_detect_provider();
    is($p, undef, 'no provider when Ollama unreachable and no OpenAI key');
};

# === Test 5: Entity embedding + search (mock) ===

subtest 'Entity embedding storage' => sub {
    my $dbh = $store->dbh;

    # Create test entities.
    $wm->add_entity(type => 'concept', name => 'rain', attributes => { description => 'water falling from sky' });
    $wm->add_entity(type => 'concept', name => 'sun', attributes => { description => 'star at center of solar system' });
    $wm->add_entity(type => 'concept', name => 'cloud', attributes => { description => 'visible mass of water droplets' });

    my @ids = map { $_->{id} } @{$wm->query_entities(type => 'concept')};
    is(scalar @ids, 3, '3 test entities');

    # Manually insert mock embeddings.
    my $rain_vec = [0.9, 0.1, 0.0, 0.0];
    my $cloud_vec = [0.8, 0.2, 0.0, 0.0];
    my $sun_vec = [0.0, 0.0, 0.9, 0.1];

    for my $i (0..$#ids) {
        my $vec = [$rain_vec, $sun_vec, $cloud_vec]->[$i];
        $dbh->prepare(
            'INSERT INTO wm_embeddings (entity_id,embedding,model,dimensions,created_at) VALUES (?,?,?,?,?)'
        )->execute($ids[$i], join(',', @$vec), 'mock', 4, int(time() * 1000));
    }

    my $count = $dbh->selectrow_array('SELECT COUNT(*) FROM wm_embeddings');
    is($count, 3, '3 embeddings stored');

    # Mock semantic search: embed query, compare against stored vectors.
    my $query_vec = [0.85, 0.15, 0.0, 0.0];   # similar to rain/cloud
    my $rows = $dbh->selectall_arrayref(
        'SELECT e.entity_id, e.embedding, en.name FROM wm_embeddings e JOIN wm_entities en ON en.id = e.entity_id',
        { Slice => {} });

    my @scored;
    for my $row (@$rows) {
        my $vec = [split /,/, $row->{embedding}];
        my $score = Clam::Wits::Embedding::Embedding::_cosine_sim($query_vec, $vec);
        push @scored, { name => $row->{name}, score => $score };
    }

    @scored = sort { $b->{score} <=> $a->{score} } @scored;
    is($scored[0]{name}, 'rain', 'rain is most similar to water query');
    ok($scored[0]{score} > $scored[2]{score}, 'rain scores higher than sun');
};

# === Test 6: Ollama embed (live, skip if unavailable) ===

subtest 'Ollama embedding (live)' => sub {
    eval {
        require HTTP::Tiny;
        my $http = HTTP::Tiny->new(timeout => 2);
        my $res = $http->get('http://localhost:11434/api/tags');
        plan skip_all => 'Ollama not running' unless $res->{success};
    };
    plan skip_all => 'HTTP::Tiny not available' if $@;

    require Clam::Wits::Embedding::Embedding;

    my $provider = {
        name     => 'ollama',
        base_url => 'http://localhost:11434',
        model    => 'nomic-embed-text',
    };

    my $vec = eval { Clam::Wits::Embedding::Embedding::_embed_ollama($provider, 'hello world') };
    plan skip_all => "Ollama embedding failed: $provider->{error}" unless $vec;

    ok(ref $vec eq 'ARRAY', 'returns arrayref');
    ok(scalar @$vec > 0, 'has dimensions');
    ok(scalar @$vec >= 100, 'reasonable dimension count (' . scalar(@$vec) . ')');

    # Cosine similarity test.
    my $vec2 = Clam::Wits::Embedding::Embedding::_embed_ollama($provider, 'hello world');
    my $sim = Clam::Wits::Embedding::Embedding::_cosine_sim($vec, $vec2);
    ok($sim > 0.99, 'identical text scores near 1.0');

    my $vec3 = Clam::Wits::Embedding::Embedding::_embed_ollama($provider, 'quantum physics');
    my $sim2 = Clam::Wits::Embedding::Embedding::_cosine_sim($vec, $vec3);
    ok($sim2 < $sim, 'different text scores lower');
};

done_testing();
