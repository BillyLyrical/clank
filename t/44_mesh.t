use strict; use warnings;
use Test::More;
use lib 'lib';

# Test cross-session communication via Clank::Mesh.

use Clank::Store;
use Clank::Bus;
use Clank::Mesh;

# --- setup: two sessions sharing the same store + bus ---

my $store = Clank::Store->new(db => ':memory:');
my $bus = Clank::Bus->new(store => $store, sender => 'test');

# Session A
my $mesh_a = Clank::Mesh->new(
    bus        => $bus,
    store      => $store,
    session_id => 'session-a',
);

# Session B
my $mesh_b = Clank::Mesh->new(
    bus        => $bus,
    store      => $store,
    session_id => 'session-b',
);

# --- test 1: send and receive ---

my @received_b;
$mesh_b->on_message(sub {
    my ($msg) = @_;
    push @received_b, $msg;
});

$mesh_b->subscribe;

my $result = $mesh_a->send('session-b', { text => 'hello from A' });
ok($result->{ok}, 'send returned ok');
ok($result->{event_id}, 'send returned event_id');
is($result->{topic}, 'session.session-b.message', 'sent to correct topic');

# Give the bus a moment to dispatch (synchronous, but let's be safe).
is(scalar @received_b, 1, 'session B received 1 message');
is($received_b[0]{from}, 'session-a', 'message from session A');
is($received_b[0]{payload}{text}, 'hello from A', 'message payload correct');

# --- test 2: bidirectional communication ---

my @received_a;
$mesh_a->on_message(sub {
    my ($msg) = @_;
    push @received_a, $msg;
});
$mesh_a->subscribe;

$mesh_b->send('session-a', { text => 'hello back from B' });
is(scalar @received_a, 1, 'session A received reply');
is($received_a[0]{from}, 'session-b', 'reply from session B');
is($received_a[0]{payload}{text}, 'hello back from B', 'reply payload correct');

# --- test 3: broadcast ---

my @broadcast_a;
$mesh_a->on_message(sub {
    my ($msg) = @_;
    push @broadcast_a, $msg if $msg->{payload}{_broadcast};
});

$mesh_b->broadcast({ announcement => 'B is online' });
# Broadcast goes to mesh.broadcast topic — both sessions would need to
# subscribe to mesh.broadcast to receive it. Let's subscribe A.
$bus->subscribe('mesh.broadcast', sub {
    my ($ev) = @_;
    push @broadcast_a, {
        from    => $ev->{payload}{_from_session} // 'unknown',
        payload => $ev->{payload},
    };
    return undef;
});

$mesh_b->broadcast({ announcement => 'B is broadcasting' });
ok(scalar @broadcast_a >= 1, 'broadcast received');

# --- test 4: unsubscribe stops messages ---

$mesh_b->unsubscribe;

@received_b = ();
$mesh_a->send('session-b', { text => 'should not arrive' });
is(scalar @received_b, 0, 'unsubscribed session does not receive');

# --- test 5: query messages from journal ---

# Send a few more messages.
$mesh_a->send('session-b', { text => 'msg 1' });
$mesh_a->send('session-b', { text => 'msg 2' });
$mesh_b->subscribe;   # re-subscribe
$mesh_b->send('session-a', { text => 'msg 3' });

my $msgs = $mesh_a->query_messages(from => 'session-b', limit => 10);
ok(@$msgs >= 1, 'query_messages returns messages from session B');
my @from_b = grep { $_->{from} eq 'session-b' } @$msgs;
ok(@from_b >= 1, 'query_messages filtered to session B');

# --- test 6: query all messages ---

my $all = $mesh_a->query_messages(limit => 100);
ok(@$all >= 3, 'query_messages without filter returns all messages');

# --- test 7: mesh is not required for basic operation ---

my $bus2 = Clank::Bus->new(store => $store, sender => 'test2');
my $mesh_c = Clank::Mesh->new(bus => $bus2, session_id => 'session-c');
# No subscribe, no handlers — should not crash.
my $r = $mesh_c->send('session-d', { text => 'test' });
ok($r->{ok}, 'send without subscribe still works (fire-and-forget)');

done_testing();
