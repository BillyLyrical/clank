#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

use Clank::Pipeline;

# === Test 1: Module loads ===

subtest 'Module loads' => sub {
    use_ok('Clank::Pipeline');
};

# === Test 2: Parse simple pipeline ===

subtest 'Parse simple pipeline' => sub {
    my $text = <<'END';
# Code Review Pipeline
Pipeline[
  name("code-review")
  about("Review code changes")
]

Source[
  name("diff-source")
  topic("git.diff.ready")
]

Agent[
  name("critic")
  wit("logic")
  tool("critique_code")
  subscribe("git.diff.ready")
  publish("critic.output")
]

Sink[
  name("review-sink")
  subscribe("critic.output")
  topic("review.complete")
]
END

    my $p = Clank::Pipeline->parse($text);
    is($p->{name}, 'code-review', 'pipeline name parsed');
    is($p->{about}, 'Review code changes', 'pipeline about parsed');
    is(scalar @{ $p->{sources} }, 1, 'one source');
    is(scalar @{ $p->{agents} }, 1, 'one agent');
    is(scalar @{ $p->{sinks} }, 1, 'one sink');
    is($p->{sources}[0]{topic}, 'git.diff.ready', 'source topic');
    is($p->{agents}[0]{name}, 'critic', 'agent name');
    is($p->{agents}[0]{subscribe}[0], 'git.diff.ready', 'agent subscribe');
    is($p->{agents}[0]{publish}, 'critic.output', 'agent publish');
    is($p->{sinks}[0]{subscribe}[0], 'critic.output', 'sink subscribe');
};

# === Test 3: Parse multi-subscribe agent ===

subtest 'Parse multi-subscribe' => sub {
    my $text = <<'END';
Pipeline[
  name("merge-test")
  about("merge two sources")
]

Agent[
  name("merger")
  subscribe("source1.output")
  subscribe("source2.output")
  publish("merged.output")
]
END

    my $p = Clank::Pipeline->parse($text);
    is(scalar @{ $p->{agents}[0]{subscribe} }, 2, 'two subscribe topics');
    is($p->{agents}[0]{subscribe}[0], 'source1.output', 'first topic');
    is($p->{agents}[0]{subscribe}[1], 'source2.output', 'second topic');
};

# === Test 4: Parse ignores comments ===

subtest 'Parse ignores comments' => sub {
    my $text = <<'END';
# This is a comment
Pipeline[
  name("test") # inline comment
  about("test pipeline")
]
END

    my $p = Clank::Pipeline->parse($text);
    is($p->{name}, 'test', 'parsed despite comments');
    is($p->{about}, 'test pipeline', 'about parsed');
};

# === Test 5: List pipelines ===

subtest 'List pipelines' => sub {
    my $dir = "$FindBin::Bin/../_test_pipelines";
    mkdir $dir unless -d $dir;
    # Create a test pipeline file.
    open my $fh, '>', "$dir/test-pipe.clank" or die $!;
    print $fh "Pipeline[\n  name(\"test-pipe\")\n  about(\"test\")\n]\n";
    close $fh;

    Clank::Pipeline->pipeline_dir($dir);
    my @names = Clank::Pipeline->list;
    ok(grep { $_ eq 'test-pipe' } @names, 'found test pipeline');

    unlink "$dir/test-pipe.clank";
    rmdir $dir;
};

# === Test 6: Load pipeline ===

subtest 'Load pipeline' => sub {
    my $dir = "$FindBin::Bin/../_test_pipelines";
    mkdir $dir unless -d $dir;
    open my $fh, '>', "$dir/load-test.clank" or die $!;
    print $fh <<'END';
Pipeline[
  name("load-test")
  about("loaded pipeline")
]

Source[
  name("src")
  topic("input.ready")
]
END
    close $fh;

    Clank::Pipeline->pipeline_dir($dir);
    my $p = Clank::Pipeline->load('load-test');
    ok($p, 'loaded pipeline');
    is($p->{name}, 'load-test', 'name correct');
    is(scalar @{ $p->{sources} }, 1, 'one source');

    unlink "$dir/load-test.clank";
    rmdir $dir;
};

# === Test 7: Load nonexistent returns undef ===

subtest 'Load nonexistent' => sub {
    my $p = Clank::Pipeline->load('nonexistent_pipeline_xyz');
    is($p, undef, 'returns undef');
};

# === Test 8: Parse empty/whitespace ===

subtest 'Parse edge cases' => sub {
    my $p = Clank::Pipeline->parse('');
    is($p->{name}, undef, 'empty text');
    is(scalar @{ $p->{sources} }, 0, 'no sources');
    is(scalar @{ $p->{agents} }, 0, 'no agents');
    is(scalar @{ $p->{sinks} }, 0, 'no sinks');
};

done_testing;
