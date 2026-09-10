# Section 4: Clank::Pipeline — Parser, Blueprint Loading, Execution, Inline Pipes
use strict; use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::RealBin/../lib";
use File::Temp qw(tempdir);
use IPC::Open3;
use Symbol;
use Clank::Pipeline;
use Clank::Util qw(jencode jdecode);

# =============================================================================
# 4.1 — Parser Unit Tests
# =============================================================================
subtest '4.1a: basic pipeline metadata' => sub {
    my $p = Clank::Pipeline->parse(<<'END');
Pipeline[
  name("test")
  about("desc")
]
END
    is($p->{name}, 'test', 'name parsed');
    is($p->{about}, 'desc', 'about parsed');
};

subtest '4.1b: # inside quotes preserved' => sub {
    my $p = Clank::Pipeline->parse("Pipeline[\n  name(\"has # inside\")\n]");
    is($p->{name}, 'has # inside', '# inside quotes not stripped');
};

subtest '4.1c: inline comment stripped' => sub {
    my $p = Clank::Pipeline->parse("Pipeline[\n  name(\"test\") # inline comment\n]");
    is($p->{name}, 'test', 'inline comment stripped, prop parsed');
};

subtest '4.1d: full blueprint with all block types' => sub {
    my $p = Clank::Pipeline->parse(<<'END');
Pipeline[
  name("full-test")
  about("all block types")
]

Source[
  name("src")
  topic("full.input")
]

Agent[
  name("worker")
  wit("logic")
  tool("process")
  subscribe("full.input")
  publish("full.output")
]

Sink[
  name("out")
  subscribe("full.output")
  topic("full.done")
]
END
    is($p->{name}, 'full-test', 'pipeline name');
    is($p->{about}, 'all block types', 'pipeline about');
    is(scalar @{ $p->{sources} }, 1, 'one source');
    is(scalar @{ $p->{agents} }, 1, 'one agent');
    is(scalar @{ $p->{sinks} }, 1, 'one sink');
    is($p->{sources}[0]{topic}, 'full.input', 'source topic');
    is($p->{agents}[0]{name}, 'worker', 'agent name');
    is($p->{agents}[0]{wit}, 'logic', 'agent wit');
    is($p->{agents}[0]{tool}, 'process', 'agent tool');
    is($p->{agents}[0]{subscribe}[0], 'full.input', 'agent subscribe');
    is($p->{agents}[0]{publish}, 'full.output', 'agent publish');
    is($p->{sinks}[0]{subscribe}[0], 'full.output', 'sink subscribe');
    is($p->{sinks}[0]{topic}, 'full.done', 'sink topic');
};

subtest '4.1e: multi-subscribe agent' => sub {
    my $p = Clank::Pipeline->parse(<<'END');
Pipeline[ name("multi") ]
Agent[
  name("merger")
  subscribe("src1.out")
  subscribe("src2.out")
  publish("merged.out")
]
END
    is(scalar @{ $p->{agents}[0]{subscribe} }, 2, 'two subscribe topics');
    is($p->{agents}[0]{subscribe}[0], 'src1.out', 'first topic');
    is($p->{agents}[0]{subscribe}[1], 'src2.out', 'second topic');
};

subtest '4.1f: comments stripped' => sub {
    my $p = Clank::Pipeline->parse(<<'END');
# This is a comment
Pipeline[
  name("test") # inline
]
# Another comment
END
    is($p->{name}, 'test', 'parsed despite comments');
};

subtest '4.1g: whitespace-only lines skipped' => sub {
    my $p = Clank::Pipeline->parse("Pipeline[\n  name(\"ws\")\n   \n  \t\n]");
    is($p->{name}, 'ws', 'whitespace-only lines ignored');
};

subtest '4.1h: empty text' => sub {
    my $p = Clank::Pipeline->parse('');
    is($p->{name}, undef, 'empty: no name');
    is(scalar @{ $p->{sources} }, 0, 'empty: no sources');
    is(scalar @{ $p->{agents} }, 0, 'empty: no agents');
    is(scalar @{ $p->{sinks} }, 0, 'empty: no sinks');
};

subtest '4.1i: unknown block types ignored' => sub {
    my $p = Clank::Pipeline->parse(<<'END');
Pipeline[
  name("t")
]
WeirdBlock[
  name("w")
]
END
    is($p->{name}, 't', 'pipeline parsed');
    is(scalar @{ $p->{sources} }, 0, 'WeirdBlock not categorized');
};

subtest '4.1j: sink with multiple subscribes' => sub {
    my $p = Clank::Pipeline->parse(<<'END');
Pipeline[ name("t") ]
Sink[
  name("out")
  subscribe("a.x")
  subscribe("b.y")
  topic("done")
]
END
    is(scalar @{ $p->{sinks}[0]{subscribe} }, 2, 'sink has two subscribes');
    is($p->{sinks}[0]{subscribe}[0], 'a.x', 'first');
    is($p->{sinks}[0]{subscribe}[1], 'b.y', 'second');
};

# =============================================================================
# 4.2 — Blueprint Loading
# =============================================================================
subtest '4.2a: list returns sorted .clank files' => sub {
    my $dir = tempdir(CLEANUP => 1);
    for my $n ('zebra', 'alpha', 'middle') {
        open my $fh, '>', "$dir/$n.clank" or die $!;
        print $fh "Pipeline[\n  name(\"$n\")\n]\n";
        close $fh;
    }
    Clank::Pipeline->pipeline_dir($dir);
    my @got = Clank::Pipeline->list;
    is_deeply(\@got, ['alpha', 'middle', 'zebra'], 'sorted');
};

subtest '4.2b: load returns parsed hashref' => sub {
    my $dir = tempdir(CLEANUP => 1);
    open my $fh, '>', "$dir/test.clank" or die $!;
    print $fh "Pipeline[\n  name(\"test\")\n  about(\"loaded\")\n]\n";
    close $fh;
    Clank::Pipeline->pipeline_dir($dir);
    my $p = Clank::Pipeline->load('test');
    ok($p, 'loaded');
    is($p->{name}, 'test', 'name');
    is($p->{about}, 'loaded', 'about');
};

subtest '4.2c: load nonexistent returns undef' => sub {
    my $dir = tempdir(CLEANUP => 1);
    Clank::Pipeline->pipeline_dir($dir);
    is(Clank::Pipeline->load('nope'), undef, 'undef');
};

# =============================================================================
# 4.3 — Blueprint Files (test artifacts)
# =============================================================================
{
    my $dir = tempdir(CLEANUP => 1);
    Clank::Pipeline->pipeline_dir($dir);

    my %blueprints = (
        simple => "Pipeline[\n  name(\"simple\")\n  about(\"simple test pipeline\")\n]\n\nSource[\n  name(\"src\")\n  topic(\"test.input\")\n]\n\nAgent[\n  name(\"echo\")\n  wit(\"psh\")\n  tool(\"eval\")\n  subscribe(\"test.input\")\n  publish(\"test.output\")\n]\n\nSink[\n  name(\"out\")\n  subscribe(\"test.output\")\n  topic(\"test.done\")\n]\n",
        fork => "Pipeline[\n  name(\"fork\")\n  about(\"fan-out test\")\n]\n\nSource[\n  name(\"src\")\n  topic(\"fork.input\")\n]\n\nAgent[\n  name(\"a1\")\n  wit(\"psh\")\n  tool(\"eval\")\n  subscribe(\"fork.input\")\n  publish(\"fork.a1\")\n]\n\nAgent[\n  name(\"a2\")\n  wit(\"psh\")\n  tool(\"eval\")\n  subscribe(\"fork.input\")\n  publish(\"fork.a2\")\n]\n\nSink[\n  name(\"out\")\n  subscribe(\"fork.a1\")\n  subscribe(\"fork.a2\")\n  topic(\"fork.done\")\n]\n",
        merge => "Pipeline[\n  name(\"merge\")\n  about(\"fan-in test\")\n]\n\nSource[\n  name(\"src\")\n  topic(\"merge.input\")\n]\n\nAgent[\n  name(\"split\")\n  wit(\"psh\")\n  tool(\"eval\")\n  subscribe(\"merge.input\")\n  publish(\"merge.split\")\n]\n\nAgent[\n  name(\"process\")\n  wit(\"psh\")\n  tool(\"eval\")\n  subscribe(\"merge.split\")\n  publish(\"merge.done\")\n]\n\nSink[\n  name(\"out\")\n  subscribe(\"merge.done\")\n  topic(\"merge.result\")\n]\n",
    );

    for my $name (sort keys %blueprints) {
        open my $fh, '>', "$dir/$name.clank" or die $!;
        print $fh $blueprints{$name};
        close $fh;
    }

    subtest '4.3a: list finds all test pipelines' => sub {
        my @names = Clank::Pipeline->list;
        ok(grep { $_ eq 'simple' } @names, 'simple');
        ok(grep { $_ eq 'fork' } @names, 'fork');
        ok(grep { $_ eq 'merge' } @names, 'merge');
    };

    subtest '4.3b: load simple' => sub {
        my $p = Clank::Pipeline->load('simple');
        ok($p, 'loaded');
        is($p->{name}, 'simple', 'name');
        is(scalar @{ $p->{sources} }, 1, 'one source');
        is(scalar @{ $p->{agents} }, 1, 'one agent');
        is(scalar @{ $p->{sinks} }, 1, 'one sink');
    };

    subtest '4.3c: load fork' => sub {
        my $p = Clank::Pipeline->load('fork');
        ok($p, 'loaded');
        is(scalar @{ $p->{agents} }, 2, 'two agents');
        is(scalar @{ $p->{sinks}[0]{subscribe} }, 2, 'sink two subscribes');
    };

    subtest '4.3d: load merge' => sub {
        my $p = Clank::Pipeline->load('merge');
        ok($p, 'loaded');
        is(scalar @{ $p->{agents} }, 2, 'two agents');
        is($p->{agents}[0]{publish}, 'merge.split', 'chain link');
        is($p->{agents}[1]{subscribe}[0], 'merge.split', 'chain target');
    };
}

# =============================================================================
# 4.4 + 4.5 — Pipeline Execution + Inline Pipes (via clankd)
# =============================================================================
{
    my @clankd_cmd = ($^X, "$FindBin::RealBin/../bin/clankd", '--stdio', '--provider', 'mock', '--db', ':memory:');
    sub spawn_clankd {
        my ($w, $r); my $e = Symbol::gensym;
        my $pid = IPC::Open3::open3($w, $r, $e, @clankd_cmd);
        return ($r, $w, $e, $pid);
    }
    sub rpc {
        my ($w, $r, $req) = @_;
        print {$w} jencode($req), "\n";
        my $line = <$r>;
        die "no response" unless defined $line;
        chomp $line;
        return jdecode($line);
    }
    sub shutdown_clankd {
        my ($w, $r, $e, $pid) = @_;
        eval { rpc($w, $r, { id => 9999, command => 'shutdown' }) };
        close $w; close $r; close $e;
        waitpid($pid, 0);
    }

    subtest '4.4a: % list via clankd' => sub {
        my ($r, $w, $e, $pid) = spawn_clankd();
        my $resp = rpc($w, $r, { id => 1, prompt => '% list' });
        is($resp->{ok}, 1, '% list ok');
        like($resp->{output} // '', qr/pipeline|found|output/i, '% list returns result');
        shutdown_clankd($w, $r, $e, $pid);
    };

    subtest '4.4b: % nonexistent via clankd' => sub {
        my ($r, $w, $e, $pid) = spawn_clankd();
        my $resp = rpc($w, $r, { id => 1, prompt => '% no_such_pipeline' });
        is($resp->{ok}, 1, '% nonexistent ok');
        like($resp->{output} // '', qr/not found/i, 'not found');
        shutdown_clankd($w, $r, $e, $pid);
    };

    subtest '4.4c: % (bare) via clankd' => sub {
        my ($r, $w, $e, $pid) = spawn_clankd();
        my $resp = rpc($w, $r, { id => 1, prompt => '%' });
        is($resp->{ok}, 1, '% bare ok');
        like($resp->{output} // '', qr/usage/i, 'usage');
        shutdown_clankd($w, $r, $e, $pid);
    };

    subtest '4.5a: > single stage via clankd' => sub {
        my ($r, $w, $e, $pid) = spawn_clankd();
        my $resp = rpc($w, $r, { id => 1, prompt => '> summarize' });
        is($resp->{ok}, 1, '> single ok');
        shutdown_clankd($w, $r, $e, $pid);
    };

    subtest '4.5b: > two stages via clankd' => sub {
        my ($r, $w, $e, $pid) = spawn_clankd();
        my $resp = rpc($w, $r, { id => 1, prompt => '> summarize | classify' });
        is($resp->{ok}, 1, '> two stages ok');
        shutdown_clankd($w, $r, $e, $pid);
    };

    subtest '4.5c: > three stages via clankd' => sub {
        my ($r, $w, $e, $pid) = spawn_clankd();
        my $resp = rpc($w, $r, { id => 1, prompt => '> summarize | classify | critique' });
        is($resp->{ok}, 1, '> three stages ok');
        shutdown_clankd($w, $r, $e, $pid);
    };

    subtest '4.5d: > (bare) via clankd' => sub {
        my ($r, $w, $e, $pid) = spawn_clankd();
        my $resp = rpc($w, $r, { id => 1, prompt => '>' });
        is($resp->{ok}, 1, '> bare ok');
        like($resp->{output} // '', qr/usage/i, 'usage');
        shutdown_clankd($w, $r, $e, $pid);
    };

    subtest '4.5e: > whitespace around pipes via clankd' => sub {
        my ($r, $w, $e, $pid) = spawn_clankd();
        my $resp = rpc($w, $r, { id => 1, prompt => '>  a  |  b  ' });
        is($resp->{ok}, 1, '> whitespace ok');
        shutdown_clankd($w, $r, $e, $pid);
    };
}

done_testing;
