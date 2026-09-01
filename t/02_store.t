use strict; use warnings;
use Test::More;
use lib 'lib';
use Clam::Store;
use Clam::Messages;

my $store = Clam::Store->new(path => ':memory:');
isa_ok($store, 'Clam::Store');

# sessions
my $sid = $store->create_session(title => 'test', cwd => '/tmp');
ok($sid && length $sid, 'session created');
my $srow = $store->get_session($sid);
is($srow->{title}, 'test', 'session title');
$store->set_session_title($sid, 'renamed');
$srow = $store->get_session($sid);
is($srow->{title}, 'renamed', 'title updated');

# message tree: linear chain then a branch
my $m1 = Clam::Messages::add($store, $sid, role => 'user', content => 'hello');
my $m2 = Clam::Messages::add($store, $sid, role => 'assistant', content => { text => 'hi' });
is(Clam::Messages::head($store, $sid), $m2, 'head is newest');

# branch from m1 (parent_id explicit)
my $b1 = Clam::Messages::add($store, $sid, role => 'user', content => 'branch?', parent_id => $m1);
my @chain = @{ Clam::Messages::chain($store, $sid, $b1) };
is(scalar(@chain), 2, 'branched chain has 2 messages');
is($chain[0]{id}, $m1, 'branch root is m1');

# main head still at m2
my @main = @{ Clam::Messages::chain($store, $sid) };
is(scalar(@main), 2, 'main chain has 2 messages');
is($main[1]{id}, $m2, 'main head is m2');

# provider mapping
my $pm = Clam::Messages::to_provider($main[1]);
is($pm->{role}, 'assistant', 'assistant role mapped');
is($pm->{content}, 'hi', 'assistant text mapped');

my $tr = Clam::Messages::add($store, $sid, role => 'toolResult',
    content => { tool_call_id => 'tc1', output => 'ok', isError => 0 });
my $pmt = Clam::Messages::to_provider({ %{$main[1]}, id => $tr, role => 'toolResult',
    content => { tool_call_id => 'tc1', output => 'ok' } });
is($pmt->{role}, 'tool', 'toolResult maps to tool');
is($pmt->{tool_call_id}, 'tc1', 'tool_call_id preserved');

# events journal
my $eid = $store->log_event(topic => 'test.topic', sender => 't', payload => { a => 1 });
ok($eid, 'event journaled');
my @evs = @{ $store->query_events(topic => 'test.topic') };
is(scalar(@evs), 1, 'event query by topic');
is($evs[0]{payload}{a}, 1, 'payload decoded');

# kv
$store->kv_set('k', { v => 42 });
is_deeply($store->kv_get('k'), { v => 42 }, 'kv roundtrip');

# rag + FTS5 (if available)
if ($store->has_fts) {
    $store->rag_add(source => 'a.md', chunk_text => 'the quick brown fox jumps');
    my @hits = @{ $store->rag_search('quick fox') };
    ok(@hits >= 1, 'fts5 search hits');
    like($hits[0]{chunk_text}, qr/quick/, 'fts5 hit content');
} else {
    skip 'no FTS5', 2;
}

done_testing();
