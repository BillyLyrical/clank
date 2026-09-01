use strict; use warnings;
use Test::More;
use lib 'lib';
use Clam::Store;
use Clam::Bus;

my $store = Clam::Store->new(path => ':memory:');
my $bus   = Clam::Bus->new(store => $store, sender => 'test');

# basic pub/sub with result capture
my @got;
$bus->subscribe('agent.turn_end', sub { push @got, $_[0]{payload}{turn}; return { saw => 1 } }, name => 't1');
my $pub = $bus->publish('agent.turn_end', { turn => 7 });
is_deeply(\@got, [7], 'subscriber got payload');
is($pub->{results}[0]{saw}, 1, 'handler result captured');

# glob matching: tool.* matches one segment deeper
my @tool_events;
$bus->subscribe('tool.*', sub { push @tool_events, $_[0]{topic} });
$bus->publish('tool.call.bash', {});   # two segments after tool -> should NOT match '*' (one segment)
$bus->publish('tool.call', {});        # one segment -> matches
is_deeply(\@tool_events, ['tool.call'], 'glob * = single segment');

# wildcard * matches everything
my $count = 0;
$bus->subscribe('*', sub { $count++ });
$bus->publish('anything.at.all', {});
ok($count >= 1, '* matches all topics');

# handler errors are isolated + journaled under wit.error
$bus->subscribe('boom.topic', sub { die "kaboom\n" }, name => 'bad');
my $r = eval { $bus->publish('boom.topic', {}); 1 };
ok($r, 'throwing handler does not kill publish');
my @errs = @{ $store->query_events(topic => 'wit.error') };
is(scalar(@errs), 1, 'error journaled to wit.error');
like($errs[0]{payload}{error}, qr/kaboom/, 'error message captured');

# request/reply
$bus->subscribe('task.ping', sub {
    my ($ev) = @_;
    $bus->publish('result.ping', { pong => 1 }, correlation_id => $ev->{correlation_id});
    return undef;
}, name => 'pinger');
my $reply = $bus->request('task.ping', {}, timeout_ms => 2000);
is_deeply($reply, { pong => 1 }, 'request/reply roundtrip');

# request times out -> undef (no responder)
my $t0 = time;
my $none = $bus->request('task.nobody_home', {}, timeout_ms => 300);
is($none, undef, 'unanswered request returns undef');
ok(time - $t0 < 5, 'timeout was bounded');

# journal order: all events persisted in order
my @all = @{ $store->query_events(limit => 100) };
ok(scalar(@all) >= 6, 'events journaled');

done_testing();
