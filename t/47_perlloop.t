use strict; use warnings;
use Test::More;
use lib 'lib';

# Test PerlLoop: agent loop connecting LLM to PerlEnv.

use Clank::Store;
use Clank::Bus;
use Clank::PerlEnv;
use Clank::PerlLoop;

# --- mock provider ---

package MockProvider {
    sub new { bless { model => 'mock' }, shift }
    sub chat_payload {
        my ($self, %args) = @_;
        return { messages => $args{messages}, model => $self->{model} };
    }
    sub chat {
        my ($self, $payload) = @_;
        my $prompt = $payload->{messages}[-1]{content} // '';
        # Generate code based on the task.
        if ($prompt =~ /print.*hello/i) {
            return { choices => [{ message => { content => 'print "hello"' } }] };
        }
        if ($prompt =~ /add.*numbers/i) {
            return { choices => [{ message => { content => 'print "result=6\nSUCCESS\n"' } }] };
        }
        if ($prompt =~ /do something that fails/i) {
            return { choices => [{ message => { content => 'print "FAIL: cannot do this"' } }] };
        }
        if ($prompt =~ /fix.*error/i && $prompt =~ /Iteration 2/) {
            return { choices => [{ message => { content => 'print "result=42\nSUCCESS\n"' } }] };
        }
        if ($prompt =~ /fix.*error/i) {
            return { choices => [{ message => { content => 'die "broken"' } }] };
        }
        if ($prompt =~ /counting/i) {
            my $iter = () = $prompt =~ /Iteration/g;
            if ($iter >= 2) {
                return { choices => [{ message => { content => 'print "count=3\nSUCCESS\n"' } }] };
            }
            return { choices => [{ message => { content => 'print "count=1\n"' } }] };
        }
        # Default: simple print
        return { choices => [{ message => { content => 'print "ok\nSUCCESS\n"' } }] };
    }
    sub log_safe { 'mock' }
}

# --- mock session ---

package MockSession {
    sub new { bless {}, shift }
    sub id { 'test-session' }
}

package MockAPI {
    sub new {
        my ($class, %args) = @_;
        return bless { bus => $args{bus}, store => $args{store} }, $class;
    }
    sub bus { $_[0]->{bus} }
    sub store { $_[0]->{store} }
    sub on { return 1 }
}

package main;

# --- setup ---

my $store = Clank::Store->new(db => ':memory:');
my $bus = Clank::Bus->new(store => $store, sender => 'test');
my $provider = MockProvider->new;
my $session = MockSession->new;
my $perl_env = Clank::PerlEnv->new(store => $store, bus => $bus);

my $loop = Clank::PerlLoop->new(
    store    => $store,
    bus      => $bus,
    provider => $provider,
    session  => $session,
    perl_env => $perl_env,
    max_iters => 5,
);
$loop->register(MockAPI->new(bus => $bus, store => $store));

# --- test 1: basic code generation and execution ---

my @events;
$bus->subscribe('perl_loop.done', sub { my ($ev) = @_; push @events, $ev->{payload}; return undef; });

my $pub = $bus->publish('perl_loop.run', {
    task => 'print hello',
});
my $r = $pub->{results}[0];
ok($r->{ok}, 'basic loop succeeded');
like($r->{output}, qr/hello/, 'output contains hello');
is($r->{iterations}, 1, 'completed in 1 iteration');
ok(length($r->{code}) > 0, 'code was generated');

# --- test 2: multi-iteration loop (fix errors) ---

@events = ();
$pub = $bus->publish('perl_loop.run', {
    task => 'fix the error',
});
$r = $pub->{results}[0];
ok($r->{ok}, 'multi-iteration loop succeeded');
ok($r->{iterations} >= 2, 'took multiple iterations');
like($r->{output}, qr/42/, 'final output correct');

# --- test 3: task that fails ---

$pub = $bus->publish('perl_loop.run', {
    task => 'do something that fails',
    max_iters => 3,
});
$r = $pub->{results}[0];
is($r->{ok}, 0, 'failing task returns ok=0');

# --- test 4: task with no provider ---

my $loop_no_prov = Clank::PerlLoop->new(
    store => $store, bus => $bus,
    provider => undef, session => $session,
);
my $no_prov_result = $loop_no_prov->_on_run({
    payload => { task => 'test' },
    correlation_id => 'test-4',
});
is($no_prov_result->{ok}, 0, 'no provider returns error');
like($no_prov_result->{error}, qr/no provider/, 'error message correct');

# --- test 5: task with no session ---

my $loop_no_sess = Clank::PerlLoop->new(
    store => $store, bus => $bus,
    provider => $provider, session => undef,
);
my $no_sess_result = $loop_no_sess->_on_run({
    payload => { task => 'test' },
    correlation_id => 'test-5',
});
is($no_sess_result->{ok}, 0, 'no session returns error');

# --- test 6: empty task returns error ---

$pub = $bus->publish('perl_loop.run', { task => '' });
$r = $pub->{results}[0];
is($r->{ok}, 0, 'empty task returns error');

# --- test 7: iteration events published ---

my @iter_events;
$bus->subscribe('perl_loop.iteration', sub { my ($ev) = @_; push @iter_events, $ev->{payload}; return undef; });

$bus->publish('perl_loop.run', { task => 'add two numbers' });
ok(scalar @iter_events >= 1, 'iteration events published');
is($iter_events[0]{task}, 'add two numbers', 'iteration event has task');
ok(length($iter_events[0]{code}) > 0, 'iteration event has code');

# --- test 8: code events published ---

my @code_events;
$bus->subscribe('perl_loop.code', sub { my ($ev) = @_; push @code_events, $ev->{payload}; return undef; });

$bus->publish('perl_loop.run', { task => 'counting test' });
ok(scalar @code_events >= 1, 'code events published');
like($code_events[-1]{code} // '', qr/print/, 'code event has Perl code');

# --- test 9: done event has full history ---

$bus->publish('perl_loop.run', { task => 'print hello' });
ok(@events >= 1, 'done event published');
ok(ref $events[-1]{history} eq 'ARRAY', 'done event has history');
ok($events[-1]{iterations} >= 1, 'history has iterations');

# --- test 10: max_iters limits iterations ---

$pub = $bus->publish('perl_loop.run', {
    task => 'counting test',
    max_iters => 2,
});
$r = $pub->{results}[0];
ok($r->{iterations} <= 2, 'max_iters limits iterations');

done_testing();
