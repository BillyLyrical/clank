#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

use Clank::Sigil;

# === Test 1: Module loads ===

subtest 'Module loads' => sub {
    use_ok('Clank::Sigil');
};

# === Test 2: Constructor ===

subtest 'Constructor' => sub {
    my $s = Clank::Sigil->new(app => 'mock_app');
    isa_ok($s, 'Clank::Sigil');
    is($s->app, 'mock_app', 'app accessor works');
};

# === Test 3: Register and dispatch ===

subtest 'Register and dispatch' => sub {
    my $s = Clank::Sigil->new;
    my $captured;
    $s->register('#', sub {
        my ($app, $content) = @_;
        $captured = $content;
        return { output => 'commented' };
    });

    my $r = $s->dispatch('# this is a comment');
    is($r->{output}, 'commented', 'handler called');
    is($captured, 'this is a comment', 'content extracted');
};

# === Test 4: dispatch returns undef for bare text ===

subtest 'Bare text returns undef' => sub {
    my $s = Clank::Sigil->new;
    $s->register('/', sub { { output => 'cmd' } });

    my $r = $s->dispatch('fix the bug in Foo.pm');
    is($r, undef, 'bare text returns undef');
};

# === Test 5: dispatch returns undef for unregistered sigil ===

subtest 'Unregistered sigil returns undef' => sub {
    my $s = Clank::Sigil->new;
    $s->register('/', sub { { output => 'cmd' } });

    my $r = $s->dispatch('? what is this');
    is($r, undef, 'unregistered sigil returns undef');
};

# === Test 6: Content stripping ===

subtest 'Content stripping' => sub {
    my $s = Clank::Sigil->new;
    my @captured;
    $s->register('$', sub {
        my ($app, $content) = @_;
        push @captured, $content;
        return { output => 'ok' };
    });

    $s->dispatch('$ time()');
    $s->dispatch('$   time()');
    $s->dispatch('$time()');

    is($captured[0], 'time()', 'normal spacing');
    is($captured[1], 'time()', 'extra spaces stripped');
    is($captured[2], 'time()', 'no space after sigil');
};

# === Test 7: Empty and undef input ===

subtest 'Edge cases' => sub {
    my $s = Clank::Sigil->new;
    $s->register('/', sub { { output => 'cmd' } });

    is($s->dispatch(''), undef, 'empty string returns undef');
    is($s->dispatch(undef), undef, 'undef returns undef');
    my $r = $s->dispatch('/');
    ok($r, 'bare sigil dispatches to handler');
    is($r->{output}, 'cmd', 'bare sigil returns handler result');
};

# === Test 8: Handler error caught ===

subtest 'Handler error caught' => sub {
    my $s = Clank::Sigil->new;
    $s->register('!', sub { die "oops" });

    my $r = $s->dispatch('! 42');
    like($r->{output}, qr/sigil ! error: oops/, 'error captured');
};

# === Test 9: Multiple sigils ===

subtest 'Multiple sigils' => sub {
    my $s = Clank::Sigil->new;
    $s->register('/', sub { { output => 'command' } });
    $s->register('$', sub { { output => 'eval' } });
    $s->register('?', sub { { output => 'query' } });

    is($s->dispatch('/help')->{output}, 'command', '/ dispatches');
    is($s->dispatch('$ time()')->{output}, 'eval', '$ dispatches');
    is($s->dispatch('? what')->{output}, 'query', '? dispatches');
};

# === Test 10: is_command ===

subtest 'is_command' => sub {
    my $s = Clank::Sigil->new;
    $s->register('/', sub { { output => 'cmd' } });
    $s->register('$', sub { { output => 'eval' } });

    ok($s->is_command('/help'), '/ is command');
    ok($s->is_command('$ x'), '$ is command');
    ok(!$s->is_command('? q'), '? is not command');
    ok(!$s->is_command('bare text'), 'bare text is not command');
    ok(!$s->is_command(''), 'empty is not command');
    ok(!$s->is_command(undef), 'undef is not command');
};

# === Test 11: Register returns self (chainable) ===

subtest 'Chainable register' => sub {
    my $s = Clank::Sigil->new;
    my $ref = $s->register('/', sub { })->register('$', sub { });
    is($ref, $s, 'register returns self for chaining');
};

# === Test 12: Handler receives app ===

subtest 'Handler receives app' => sub {
    my $s = Clank::Sigil->new(app => { special => 1 });
    my $got_app;
    $s->register('/', sub {
        $got_app = $_[0];
        return { output => '' };
    });

    $s->dispatch('/test');
    is_deeply($got_app, { special => 1 }, 'handler gets app');
};

done_testing;
