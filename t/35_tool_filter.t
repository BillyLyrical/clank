#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

use Clank::Store;
use Clank::Bus;
use Clank::Session;
use Clank::Tool;
use Clank qw(builtin_tools);

# Helper: create mock tools.
sub mock_tool { Clank::Tool->new(name => $_[0], description => $_[0], parameters => { type => 'object', properties => {} }) }

# === Test 1: All tools available by default ===

subtest 'All tools by default' => sub {
    my $store = Clank::Store->new(db => ':memory:');
    my $sess  = Clank::Session->new(store => $store);
    $sess->add_tool(mock_tool('read'));
    $sess->add_tool(mock_tool('write'));
    $sess->add_tool(mock_tool('bash'));

    my @tools = $sess->tools;
    is(scalar @tools, 3, 'all 3 tools available');
};

# === Test 2: Filter restricts tools ===

subtest 'Filter restricts tools' => sub {
    my $store = Clank::Store->new(db => ':memory:');
    my $sess  = Clank::Session->new(store => $store);
    $sess->add_tool(mock_tool('read'));
    $sess->add_tool(mock_tool('write'));
    $sess->add_tool(mock_tool('bash'));

    $sess->set_tool_filter(['read', 'bash']);

    my @tools = $sess->tools;
    is(scalar @tools, 2, 'only 2 tools after filter');
    my @names = map { $_->{name} } @tools;
    ok(grep { $_ eq 'read' } @names, 'read included');
    ok(grep { $_ eq 'bash' } @names, 'bash included');
    ok(!grep { $_ eq 'write' } @names, 'write excluded');
};

# === Test 3: tool_names respects filter ===

subtest 'tool_names respects filter' => sub {
    my $store = Clank::Store->new(db => ':memory:');
    my $sess  = Clank::Session->new(store => $store);
    $sess->add_tool(mock_tool('read'));
    $sess->add_tool(mock_tool('write'));
    $sess->add_tool(mock_tool('bash'));

    $sess->set_tool_filter(['read']);

    my @names = $sess->tool_names;
    is(scalar @names, 1, 'only 1 name');
    is($names[0], 'read', 'correct name');
};

# === Test 4: Clear filter ===

subtest 'Clear filter restores all tools' => sub {
    my $store = Clank::Store->new(db => ':memory:');
    my $sess  = Clank::Session->new(store => $store);
    $sess->add_tool(mock_tool('read'));
    $sess->add_tool(mock_tool('write'));
    $sess->add_tool(mock_tool('bash'));

    $sess->set_tool_filter(['read']);
    is(scalar $sess->tools, 1, 'filtered');

    $sess->set_tool_filter(undef);
    is(scalar $sess->tools, 3, 'all restored');
};

# === Test 5: Empty filter returns nothing ===

subtest 'Empty filter returns nothing' => sub {
    my $store = Clank::Store->new(db => ':memory:');
    my $sess  = Clank::Session->new(store => $store);
    $sess->add_tool(mock_tool('read'));
    $sess->add_tool(mock_tool('write'));

    $sess->set_tool_filter([]);
    is(scalar $sess->tools, 0, 'no tools with empty filter');
};

# === Test 6: Filter with nonexistent tool names ===

subtest 'Filter with nonexistent names' => sub {
    my $store = Clank::Store->new(db => ':memory:');
    my $sess  = Clank::Session->new(store => $store);
    $sess->add_tool(mock_tool('read'));

    $sess->set_tool_filter(['read', 'nonexistent', 'also_missing']);
    is(scalar $sess->tools, 1, 'only existing tool returned');
};

done_testing;
