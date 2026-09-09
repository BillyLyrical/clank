#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

use Clank::ToolSelector;
use Clank::Tool;

# Helper: create a mock tool.
sub mock_tool {
    my ($name, $desc, $hint) = @_;
    return Clank::Tool->new(
        name        => $name,
        description => $desc,
        hint        => $hint,
        parameters  => { type => 'object', properties => {} },
    );
}

my @tools = (
    mock_tool('read',    'Read file contents from disk', 'file read cat display'),
    mock_tool('write',   'Write content to a file', 'file write create save'),
    mock_tool('edit',    'Make precise text replacements in files', 'file edit modify change replace'),
    mock_tool('bash',    'Execute shell commands', 'shell bash command run execute terminal'),
    mock_tool('git_status', 'Show git working tree status', 'git status repo repository'),
    mock_tool('git_commit', 'Create a git commit', 'git commit save checkpoint'),
    mock_tool('db_query','Execute SQL queries against a database', 'sql database query select'),
    mock_tool('search',  'Search the web for information', 'web search google bing'),
);

# === Test 1: All tools returned when under max ===

subtest 'All tools when under max' => sub {
    my $result = Clank::ToolSelector->select(tools => \@tools, prompt => 'hello', max => 20);
    is(scalar @$result, 8, 'all 8 tools returned');
};

# === Test 2: Filters when over max ===

subtest 'Filters when over max' => sub {
    my $result = Clank::ToolSelector->select(tools => \@tools, prompt => 'read the file', max => 3);
    is(scalar @$result, 3, 'limited to 3 tools');
};

# === Test 3: Relevant tools ranked first ===

subtest 'Relevant tools ranked first' => sub {
    my $result = Clank::ToolSelector->select(tools => \@tools, prompt => 'read the config file', max => 3);
    my @names = map { $_->{name} } @$result;
    is($names[0], 'read', 'read tool ranked first');
};

# === Test 4: Git tools for git prompt ===

subtest 'Git tools for git prompt' => sub {
    my $result = Clank::ToolSelector->select(tools => \@tools, prompt => 'commit my changes to git', max => 3);
    my @names = map { $_->{name} } @$result;
    ok(grep { /git/ } @names, 'git tools in results');
};

# === Test 5: Database tools for SQL prompt ===

subtest 'Database tools for SQL prompt' => sub {
    my $result = Clank::ToolSelector->select(tools => \@tools, prompt => 'query the database for users', max => 3);
    my @names = map { $_->{name} } @$result;
    is($names[0], 'db_query', 'db_query ranked first');
};

# === Test 6: Empty prompt returns all ===

subtest 'Empty prompt returns all' => sub {
    my $result = Clank::ToolSelector->select(tools => \@tools, prompt => '', max => 3);
    is(scalar @$result, 3, 'returns max tools for empty prompt');
};

# === Test 7: Single tool ===

subtest 'Single tool list' => sub {
    my $single = [mock_tool('only', 'The only tool', 'unique')];
    my $result = Clank::ToolSelector->select(tools => $single, prompt => 'anything', max => 10);
    is(scalar @$result, 1, 'single tool returned');
};

# === Test 8: No tools ===

subtest 'No tools' => sub {
    my $result = Clank::ToolSelector->select(tools => [], prompt => 'hello', max => 10);
    is(scalar @$result, 0, 'empty list for no tools');
};

# === Test 9: Recent tools boost ===

subtest 'Recent tools get boosted' => sub {
    # Without context: search, read, write (git_status not in top 3)
    my $no_ctx = Clank::ToolSelector->select(
        tools => \@tools, prompt => 'search the web', max => 3);
    my @no_names = map { $_->{name} } @$no_ctx;

    # With context: git_status was recently used, so it gets a boost
    my $with_ctx = Clank::ToolSelector->select(
        tools    => \@tools,
        prompt   => 'search the web',
        max      => 3,
        context  => { recent_tools => ['git_status'] },
    );
    my @ctx_names = map { $_->{name} } @$with_ctx;

    # git_status should appear in results with the boost (it wasn't there before)
    ok(grep({ $_ eq 'git_status' } @ctx_names), 'recent tool appears in top results');
    ok(!grep({ $_ eq 'git_status' } @no_names), 'git_status not in top without boost');
};

# === Test 10: Wit affinity boost ===

subtest 'Wit affinity boosts matching tools' => sub {
    my $result = Clank::ToolSelector->select(
        tools    => \@tools,
        prompt   => 'do something',
        max      => 4,
        context  => { loaded_wits => ['git'] },
    );
    my @names = map { $_->{name} } @$result;
    # git tools should appear in top 4 when git deck is loaded
    ok(grep { /^git/ } @names, 'git tools boosted by wit affinity');
};

# === Test 11: File type boost ===

subtest 'File type boost' => sub {
    my $result = Clank::ToolSelector->select(
        tools    => \@tools,
        prompt   => 'modify the file',
        max      => 3,
        context  => { file_types => ['pm'] },
    );
    my @names = map { $_->{name} } @$result;
    # edit tool has 'file' in its hint, should be boosted
    is($names[0], 'edit', 'edit tool boosted by file type context');
};

# === Test 12: Error recovery boost ===

subtest 'Error recovery boost' => sub {
    my $result = Clank::ToolSelector->select(
        tools    => \@tools,
        prompt   => 'fix the problem',
        max      => 3,
        context  => { error_msg => 'Can\'t locate object method "run" via package "Clank::Tool"' },
    );
    my @names = map { $_->{name} } @$result;
    # read tool should help diagnose the error
    ok(grep { /read/ } @names, 'read tool boosted for error recovery');
};

# === Test 13: Context with no signals ===

subtest 'Empty context is safe' => sub {
    my $result = Clank::ToolSelector->select(
        tools    => \@tools,
        prompt   => 'read the file',
        max      => 3,
        context  => {},
    );
    is(scalar @$result, 3, 'empty context does not break selection');
    is($result->[0]{name}, 'read', 'read still ranked first');
};

done_testing;
