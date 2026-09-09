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

done_testing;
