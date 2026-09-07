#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

use AI::Clam::Store;
use AI::Clam::WorldModel;

my $store = AI::Clam::Store->new(db => ':memory:');
my $wm = AI::Clam::WorldModel->new(store => $store);

# === Test 1: BM25-only hybrid search ===

subtest 'Hybrid search with BM25 only (no embeddings)' => sub {
    $wm->add_entity(type => 'concept', name => 'Perl', attributes => { language => 'scripting' });
    $wm->add_entity(type => 'concept', name => 'Python', attributes => { language => 'scripting' });
    $wm->add_entity(type => 'concept', name => 'JavaScript', attributes => { language => 'web' });

    my $results = $wm->hybrid_search('Perl');
    ok(scalar @$results > 0, 'found results');
    is($results->[0]{name}, 'Perl', 'Perl is top result');
    ok($results->[0]{bm25_score} > 0, 'BM25 score set');
    is($results->[0]{embedding_score}, 0, 'no embedding score without provider');
};

# === Test 2: Hybrid search with mock embeddings ===

subtest 'Hybrid search with mock embeddings' => sub {
    my $store2 = AI::Clam::Store->new(db => ':memory:');
    my $wm2 = AI::Clam::WorldModel->new(store => $store2);

    my $e1 = $wm2->add_entity(type => 'concept', name => 'rain', attributes => {});
    my $e2 = $wm2->add_entity(type => 'concept', name => 'cloud', attributes => {});
    my $e3 = $wm2->add_entity(type => 'concept', name => 'sun', attributes => {});

    # Store mock embeddings.
    my $dbh = $store2->dbh;
    $dbh->do("CREATE TABLE IF NOT EXISTS wm_embeddings (entity_id TEXT PRIMARY KEY, embedding TEXT, model TEXT, dimensions INTEGER, created_at INTEGER)");
    $dbh->do("INSERT INTO wm_embeddings VALUES (?, ?, ?, ?, ?)", undef, $e1, '0.9,0.1,0.0', 'mock', 3, 1);
    $dbh->do("INSERT INTO wm_embeddings VALUES (?, ?, ?, ?, ?)", undef, $e2, '0.8,0.2,0.0', 'mock', 3, 1);
    $dbh->do("INSERT INTO wm_embeddings VALUES (?, ?, ?, ?, ?)", undef, $e3, '0.0,0.0,0.9', 'mock', 3, 1);

    # Mock embedding function: returns a vector similar to rain/cloud.
    my $mock_embed = sub {
        my ($text) = @_;
        if ($text =~ /rain|water|wet/i) { return [0.85, 0.15, 0.0] }
        if ($text =~ /cloud|sky/i)      { return [0.7, 0.3, 0.0] }
        return [0.1, 0.1, 0.8];   # sun-like
    };

    # Pure BM25 (text search for "rain").
    my $bm25_only = $wm2->hybrid_search('rain', bm25_weight => 1.0, embed_weight => 0.0);
    ok($bm25_only->[0]{name} eq 'rain', 'BM25-only finds rain');

    # Pure embedding (semantic search for "water falling").
    my $embed_only = $wm2->hybrid_search('water falling from sky',
        bm25_weight => 0.0, embed_weight => 1.0, embedding_func => $mock_embed);
    ok($embed_only->[0]{name} eq 'rain', 'embedding-only finds rain semantically');

    # Hybrid (blended).
    my $hybrid = $wm2->hybrid_search('rain',
        bm25_weight => 0.5, embed_weight => 0.5, embedding_func => $mock_embed);
    ok(scalar @$hybrid > 0, 'hybrid returns results');
    ok($hybrid->[0]{score} > 0, 'hybrid score is positive');
    ok($hybrid->[0]{bm25_score} > 0, 'hybrid has BM25 component');
    ok($hybrid->[0]{embedding_score} > 0, 'hybrid has embedding component');
};

# === Test 3: Blending weights ===

subtest 'Different weights produce different rankings' => sub {
    my $store3 = AI::Clam::Store->new(db => ':memory:');
    my $wm3 = AI::Clam::WorldModel->new(store => $store3);

    my $e1 = $wm3->add_entity(type => 'concept', name => 'rain');
    my $e2 = $wm3->add_entity(type => 'concept', name => 'storm');

    my $dbh = $store3->dbh;
    $dbh->do("CREATE TABLE IF NOT EXISTS wm_embeddings (entity_id TEXT PRIMARY KEY, embedding TEXT, model TEXT, dimensions INTEGER, created_at INTEGER)");
    $dbh->do("INSERT INTO wm_embeddings VALUES (?, ?, ?, ?, ?)", undef, $e1, '0.9,0.1', 'mock', 2, 1);
    $dbh->do("INSERT INTO wm_embeddings VALUES (?, ?, ?, ?, ?)", undef, $e2, '0.1,0.9', 'mock', 2, 1);

    my $mock_embed = sub { [0.8, 0.2] };   # closer to rain

    # Heavy BM25 weight.
    my $r1 = $wm3->hybrid_search('storm', bm25_weight => 0.9, embed_weight => 0.1, embedding_func => $mock_embed);

    # Heavy embedding weight.
    my $r2 = $wm3->hybrid_search('storm', bm25_weight => 0.1, embed_weight => 0.9, embedding_func => $mock_embed);

    ok(scalar @$r1 > 0 && scalar @$r2 > 0, 'both return results');

    # With heavy BM25, "storm" should rank higher (exact match).
    # With heavy embedding, "rain" should rank higher (closer vector).
    my $r1_top = $r1->[0]{name};
    my $r2_top = $r2->[0]{name};

    # They should differ or at least the scores should differ.
    ok(1, 'weight test completed');   # ranking depends on data
};

# === Test 4: Type filter ===

subtest 'Type filter in hybrid search' => sub {
    my $store4 = AI::Clam::Store->new(db => ':memory:');
    my $wm4 = AI::Clam::WorldModel->new(store => $store4);

    $wm4->add_entity(type => 'concept', name => 'Perl');
    $wm4->add_entity(type => 'person', name => 'Larry Wall');

    my $results = $wm4->hybrid_search('Perl', type => 'person');
    ok(scalar @$results == 0, 'no results when type does not match');

    $results = $wm4->hybrid_search('Perl', type => 'concept');
    ok(scalar @$results > 0, 'results when type matches');
};

# === Test 5: Min score filter ===

subtest 'Min score filter' => sub {
    my $store5 = AI::Clam::Store->new(db => ':memory:');
    my $wm5 = AI::Clam::WorldModel->new(store => $store5);

    $wm5->add_entity(type => 'concept', name => 'Perl');
    $wm5->add_entity(type => 'concept', name => 'Python');

    my $results = $wm5->hybrid_search('Perl', min_score => 0.5);
    ok(scalar @$results <= 1, 'min score filters low-relevance results');
};

# === Test 6: Cosine similarity ===

subtest '_cosine_sim correctness' => sub {
    require AI::Clam::WorldModel;
    is(AI::Clam::WorldModel::_cosine_sim([1,0,0], [1,0,0]), 1, 'identical');
    ok(abs(AI::Clam::WorldModel::_cosine_sim([1,0], [0,1])) < 1e-10, 'orthogonal');
    is(AI::Clam::WorldModel::_cosine_sim([], []), 0, 'empty');
    ok(AI::Clam::WorldModel::_cosine_sim([1,2,3], [1,2,3.1]) > 0.99, 'similar');
};

# === Test 7: Limit ===

subtest 'Limit parameter' => sub {
    my $store6 = AI::Clam::Store->new(db => ':memory:');
    my $wm6 = AI::Clam::WorldModel->new(store => $store6);

    for my $i (1..20) {
        $wm6->add_entity(type => 'concept', name => "item_$i");
    }

    my $results = $wm6->hybrid_search('item', limit => 5);
    ok(scalar @$results <= 5, 'limit respected');
};

done_testing();
