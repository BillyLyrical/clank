use strict; use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::RealBin/../lib";   # absolute: test chdirs later
use File::Temp qw(tempdir);
use AI::Clam::Store;
use AI::Clam::Bus;
use AI::Clam::Session;
use AI::Clam::Loop;
use AI::Clam::Session::Messages;
use AI::Clam qw(builtin_tools);

# --- mock provider: scripted responses, records payloads --------------------
package MockProvider;
sub new { my ($c, $script) = @_; return bless { script => $script, calls => [] }, $c }
sub chat_payload { my ($s, %a) = @_; return { model => 'mock', messages => $a{messages}, tools => $a{tools} } }
sub post_json {
    my ($s, $path, $payload) = @_;
    push @{ $s->{calls} }, $payload;
    return $s->{script}->($payload, scalar @{ $s->{calls} });
}

package main;

my $dir = tempdir(CLEANUP => 1);
chdir $dir or die "chdir: $!";

sub make_env {
    my ($script) = @_;
    my $store = AI::Clam::Store->new(path => ':memory:');
    my $bus   = AI::Clam::Bus->new(store => $store, sender => 'test');
    my $mock  = MockProvider->new($script);
    my $sess  = AI::Clam::Session->new(store => $store, bus => $bus, provider => $mock);
    $sess->add_tool($_) for builtin_tools();
    my $loop  = AI::Clam::Loop->new(session => $sess);
    return ($store, $bus, $mock, $sess, $loop);
}

sub chain_of { my ($store, $sid) = @_; return AI::Clam::Session::Messages::chain($store, $sid) }

# --- 1. basic tool-call round trip ------------------------------------------
{
    my ($store, $bus, $mock, $sess, $loop) = make_env(sub {
        my ($payload, $n) = @_;
        if ($n == 1) {
            return { choices => [ { finish_reason => 'toolUse', message => {
                content => '',
                tool_calls => [ { id => 'tc1', type => 'function',
                    function => { name => 'write', arguments => '{"path":"out.txt","content":"hi from loop"}' } },
            ] } } ] };
        }
        return { choices => [ { finish_reason => 'stop', message => { content => 'all done' } } ] };
    });

    my $res = $loop->run_prompt('please write the file');
    is($res->{ok}, 1, 'loop ok');
    is($res->{turns}, 2, 'two turns (tool + final)');
    open my $ofh, '<', 'out.txt' or fail('write tool did not create out.txt');
    my $file_content = do { local $/; <$ofh> }; close $ofh;
    is($file_content, "hi from loop", 'write tool executed by loop');

    my @chain = @{ chain_of($store, $sess->id) };
    is(scalar(@chain), 4, 'user + assistant(toolcall) + toolResult + assistant(final)');
    is($chain[0]{role}, 'user', 'first is user');
    is($chain[1]{role}, 'assistant', 'second is assistant with tool call');
    is(scalar(@{ $chain[1]{content}{tool_calls} }), 1, 'assistant stored one tool call');
    is($chain[2]{role}, 'toolResult', 'third is tool result');
    is($chain[3]{content}{text}, 'all done', 'final text stored');

    # every lifecycle topic was journaled
    my %topics = map { $_->{topic} => 1 } @{ $store->query_events(limit => 200) };
    for my $t (qw(input before_agent_start agent_start turn_start context
                  before_provider_request after_provider_response message_end
                  tool_call tool_execution_start tool_result tool_execution_end
                  turn_end agent_end agent_settled)) {
        ok($topics{$t}, "topic journaled: $t");
    }

    # provider saw system prompt + tools schema
    my $p1 = $mock->{calls}[0];
    is($p1->{messages}[0]{role}, 'system', 'system message first');
    like($p1->{messages}[0]{content}, qr/expert coding assistant/, 'Pi-style system prompt');
    # NOTE: parenthesize the grep list — otherwise it swallows ok()'s description.
    my @schemas = @{ $p1->{tools} };
    ok((grep { $_->{function}{name} eq 'write' } @schemas), 'tool schemas sent to provider');
}

# --- 2. tool_call hook: block -------------------------------------------------
{
    my ($store, $bus, $mock, $sess, $loop) = make_env(sub {
        my ($payload, $n) = @_;
        if ($n == 1) {
            return { choices => [ { finish_reason => 'toolUse', message => {
                content => '', tool_calls => [ { id => 'tc9', type => 'function',
                    function => { name => 'bash', arguments => '{"command":"echo nope"}' } }, ] } } ] };
        }
        return { choices => [ { finish_reason => 'stop', message => { content => 'ok' } } ] };
    });

    $bus->subscribe('tool_call', sub {
        my ($ev) = @_;
        return { block => 1, reason => 'no bash in tests' } if $ev->{payload}{name} eq 'bash';
        return undef;
    }, name => 'guard');

    my $res = $loop->run_prompt('do a thing');
    is($res->{ok}, 1, 'blocked loop still ok');
    my @chain = @{ chain_of($store, $sess->id) };
    my ($tr) = grep { $_->{role} eq 'toolResult' } @chain;
    like($tr->{content}{output}, qr/blocked.*no bash in tests/s, 'block reason fed back to LLM');
    ok($tr->{content}{isError}, 'blocked call marked as error');
}

# --- 3. tool_call hook: mutate args in place ----------------------------------
{
    my ($store, $bus, $mock, $sess, $loop) = make_env(sub {
        my ($payload, $n) = @_;
        if ($n == 1) {
            return { choices => [ { finish_reason => 'toolUse', message => {
                content => '', tool_calls => [ { id => 'tc2', type => 'function',
                    function => { name => 'write', arguments => '{"path":"x.txt","content":"orig"}' } }, ] } } ] };
        }
        return { choices => [ { finish_reason => 'stop', message => { content => 'done' } } ] };
    });

    $bus->subscribe('tool_call', sub {
        my ($ev) = @_;
        if ($ev->{payload}{name} eq 'write') {
            $ev->{payload}{input}{content} = 'mutated';   # in-place mutation
        }
        return undef;
    }, name => 'mutator');

    $loop->run_prompt('write x');
    open my $xfh, '<', 'x.txt' or fail('x.txt missing');
    my $xc = do { local $/; <$xfh> }; close $xfh;
    is($xc, 'mutated', 'in-place arg mutation honored');
}

# --- 4. context hook: rewrite messages ----------------------------------------
{
    my ($store, $bus, $mock, $sess, $loop) = make_env(sub {
        return { choices => [ { finish_reason => 'stop', message => { content => 'hi' } } ] };
    });

    $bus->subscribe('context', sub {
        my ($ev) = @_;
        my @msgs = @{ $ev->{payload}{messages} };
        unshift @msgs, { role => 'user', content => '[INJECTED CONTEXT]' };
        return { messages => \@msgs };
    }, name => 'injector');

    $loop->run_prompt('hello');
    my $p1 = $mock->{calls}[0];
    like(join("\n", map { $_->{content} // '' } @{ $p1->{messages} }), qr/INJECTED CONTEXT/,
         'context rewrite reached provider payload');
}

# --- 5. input hook: transform + handled ----------------------------------------
{
    my ($store, $bus, $mock, $sess, $loop) = make_env(sub {
        return { choices => [ { finish_reason => 'stop', message => { content => 'hi' } } ] };
    });

    $bus->subscribe('input', sub {
        my ($ev) = @_;
        return { action => 'transform', text => $ev->{payload}{text} . ' [tagged]' };
    }, name => 'tagger');

    $loop->run_prompt('hello');
    my @chain = @{ chain_of($store, $sess->id) };
    is($chain[0]{content}, 'hello [tagged]', 'input transform applied to stored message');

    # handled: intercept entirely
    $bus->subscribe('input', sub {
        return { action => 'handled', output => 'intercepted!' };
    }, name => 'interceptor');
    my $before = scalar @{ chain_of($store, $sess->id) };
    my $res = $loop->run_prompt('secret command');
    is_deeply({ ok => $res->{ok}, handled => $res->{handled}, output => $res->{output} },
              { ok => 1, handled => 1, output => 'intercepted!' }, 'input handled short-circuits');
    my $after = scalar @{ chain_of($store, $sess->id) };
    is($after, $before, 'no messages added when handled');
}

# --- 6. message_end hook: replace finalized assistant message -------------------
{
    my ($store, $bus, $mock, $sess, $loop) = make_env(sub {
        return { choices => [ { finish_reason => 'stop', message => { content => 'original' } } ] };
    });

    $bus->subscribe('message_end', sub {
        return { role => 'assistant', content => { text => 'REPLACED', tool_calls => [] } };
    }, name => 'replacer');

    $loop->run_prompt('hi');
    my @chain = @{ chain_of($store, $sess->id) };
    is($chain[-1]{content}{text}, 'REPLACED', 'message_end replacement stored');

    # role mismatch must die (Pi semantics)
    $bus->subscribe('message_end', sub {
        return { role => 'user', content => { text => 'bad' } };
    }, name => 'badrole');
    my $res = eval { $loop->run_prompt('hi again') };
    like($@, qr/same role/, 'role mismatch rejected');
}

# --- 7. before_agent_start: systemPrompt chain + message injection --------------
{
    my ($store, $bus, $mock, $sess, $loop) = make_env(sub {
        return { choices => [ { finish_reason => 'stop', message => { content => 'hi' } } ] };
    });

    $bus->subscribe('before_agent_start', sub {
        my ($ev) = @_;
        return { systemPrompt => $ev->{payload}{systemPrompt} . "\n[EXTRA RULES]" };
    }, name => 'prompter');
    $bus->subscribe('before_agent_start', sub {
        return { message => 'injected note' };
    }, name => 'injector2');

    $loop->run_prompt('hello');
    my $p1 = $mock->{calls}[0];
    like($p1->{messages}[0]{content}, qr/EXTRA RULES/, 'systemPrompt chained replacement reached provider');
    my @chain = @{ chain_of($store, $sess->id) };
    is(scalar(@chain), 3, 'user + injected note + assistant');
    like($chain[1]{content}, qr/injected note/, 'injected message stored as user message');
}

done_testing();
