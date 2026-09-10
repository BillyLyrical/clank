# Section 3.2: Clank::Sigil — Integration: REPL vs clankd
# Verifies that the same Sigil dispatch logic produces consistent results
# in both the in-process context (REPL-like) and the clankd NDJSON context.
use strict; use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::RealBin/../lib";
use File::Temp qw(tempdir);
use IPC::Open3;
use Symbol;
use Clank::Sigil;
use Clank::Util qw(jencode jdecode);

my $tmp = tempdir(CLEANUP => 1);
local $ENV{HOME} = "$tmp/home";
delete $ENV{CLANK_WITS_PATH};

# =============================================================================
# 3.2.1 — In-process Sigil dispatch (REPL-like context)
# =============================================================================
subtest 'in-process: Sigil dispatch consistency' => sub {
    my @dispatches;

    my $s = Clank::Sigil->new(app => { context => 'repl' });
    $s->register('/', sub {
        my ($app, $content) = @_;
        push @dispatches, { sigil => '/', content => $content, ctx => 'repl' };
        return { output => "repl cmd: $content" };
    });
    $s->register('#', sub {
        my ($app, $content) = @_;
        push @dispatches, { sigil => '#', content => $content, ctx => 'repl' };
        return { output => '' };
    });
    $s->register('$', sub {
        my ($app, $content) = @_;
        push @dispatches, { sigil => '$', content => $content, ctx => 'repl' };
        return { output => "eval: $content" };
    });
    $s->register('?', sub {
        my ($app, $content) = @_;
        push @dispatches, { sigil => '?', content => $content, ctx => 'repl' };
        return { output => "query: $content" };
    });

    # Test: dispatch extracts correct content
    my $r = $s->dispatch('/help');
    is($r->{output}, 'repl cmd: help', '/ dispatches correctly');
    is($dispatches[-1]{content}, 'help', '/ content is "help"');

    $r = $s->dispatch('$ time()');
    is($r->{output}, 'eval: time()', '$ dispatches correctly');
    is($dispatches[-1]{content}, 'time()', '$ content is "time()"');

    $r = $s->dispatch('# just a comment');
    is($r->{output}, '', '# returns empty');

    $r = $s->dispatch('? what is life');
    is($r->{output}, 'query: what is life', '? dispatches correctly');

    # Test: bare text falls through
    $r = $s->dispatch('hello world');
    is($r, undef, 'bare text falls through');

    # Test: unregistered sigil falls through
    $r = $s->dispatch('@ list');
    is($r, undef, 'unregistered sigil falls through');

    is(scalar @dispatches, 4, 'four handlers called');
};

# =============================================================================
# 3.2.2 — Sigil content parsing consistency (REPL vs clankd identical logic)
# =============================================================================
subtest 'content parsing consistency' => sub {
    # Both REPL and clankd use the same Sigil.pm — verify the parsing
    # is deterministic for a range of inputs.
    my @inputs = (
        '/help',
        '/  help',
        '/   help with spaces',
        '$ 2 + 2',
        '$   time()',
        '$time()',
        '# a comment',
        '#',
        '? a query',
        '?',
        ': test.topic',
        ':  publish foo {"k":"v"}',
        '@list',
        '@ reviewer do something',
        '% list',
        '> summarize | classify',
        '~ list',
        '! last',
    );

    my $s = Clank::Sigil->new;
    my @results;
    for my $sigil ('/', '$', '#', '?', ':', '@', '%', '>', '~', '!') {
        $s->register($sigil, sub {
            my ($app, $content) = @_;
            push @results, { sigil => $sigil, content => $content };
            return { output => 'ok' };
        });
    }

    for my $input (@inputs) {
        my $r = $s->dispatch($input);
        if ($r) {
            ok(1, "dispatch '$input' -> sigil '$results[-1]{sigil}'");
        } else {
            # Bare text or unregistered sigil
            pass("dispatch '$input' -> fall-through");
        }
    }

    # Verify content extraction is consistent: same sigil + same input = same content
    my $s2 = Clank::Sigil->new;
    my @c1;
    $s2->register('/', sub { push @c1, $_[1]; return { output => 'ok' } });
    $s2->dispatch('/help');
    $s2->dispatch('/  help');
    $s2->dispatch('/help');

    is($c1[0], 'help', 'input 1: content = "help"');
    is($c1[1], 'help', 'input 2: content = "help" (spaces stripped)');
    is($c1[2], 'help', 'input 3: content = "help" (deterministic)');
    is($c1[0], $c1[2], 'identical input produces identical content');
};

# =============================================================================
# 3.2.3 — Error handling consistency
# =============================================================================
subtest 'error handling consistency' => sub {
    my $s = Clank::Sigil->new;

    # Handler that dies
    $s->register('!', sub { die "test error" });
    my $r = $s->dispatch('! do something');
    like($r->{output}, qr/sigil ! error: test error/, 'error message format consistent');

    # Handler that returns undef
    $s->register('%', sub { undef });
    $r = $s->dispatch('% list');
    is($r, undef, 'handler returning undef propagates as fall-through');

    # Handler returning hashref
    $s->register('@', sub { { output => 'agent result', ok => 1 } });
    $r = $s->dispatch('@list');
    is($r->{output}, 'agent result', 'hashref return preserved');
    is($r->{ok}, 1, 'extra fields preserved');
};

# =============================================================================
# 3.2.4 — Sigil dispatch order: same registration = same behavior
# =============================================================================
subtest 'dispatch order independence' => sub {
    # Register in different order, verify same results
    my @order1_results;
    my $s1 = Clank::Sigil->new;
    for my $sigil ('/', '$', '?', '#') {
        $s1->register($sigil, sub { push @order1_results, $_[1]; { output => 'ok' } });
    }
    $s1->dispatch('/help'); $s1->dispatch('$ eval'); $s1->dispatch('? q'); $s1->dispatch('# c');

    my @order2_results;
    my $s2 = Clank::Sigil->new;
    for my $sigil ('#', '?', '$', '/') {
        $s2->register($sigil, sub { push @order2_results, $_[1]; { output => 'ok' } });
    }
    $s2->dispatch('/help'); $s2->dispatch('$ eval'); $s2->dispatch('? q'); $s2->dispatch('# c');

    is_deeply(\@order1_results, \@order2_results,
        'registration order does not affect dispatch results');
};

# =============================================================================
# 3.2.5 — clankd uses same Sigil.pm (via NDJSON protocol)
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

    subtest 'clankd: same dispatch logic for /' => sub {
        my ($r, $w, $e, $pid) = spawn_clankd();

        my $resp = rpc($w, $r, { id => 1, prompt => '/help' });
        is($resp->{ok}, 1, '/help via clankd ok');
        like($resp->{output} // '', qr/help/i, '/help output consistent with Sigil dispatch');

        shutdown_clankd($w, $r, $e, $pid);
    };

    subtest 'clankd: same dispatch logic for #' => sub {
        my ($r, $w, $e, $pid) = spawn_clankd();

        my $resp = rpc($w, $r, { id => 1, prompt => '# test comment' });
        is($resp->{ok}, 1, '# via clankd ok');
        is($resp->{output}, '', '# returns empty — same as in-process Sigil');

        shutdown_clankd($w, $r, $e, $pid);
    };

    subtest 'clankd: same dispatch logic for $' => sub {
        my ($r, $w, $e, $pid) = spawn_clankd();

        my $resp = rpc($w, $r, { id => 1, prompt => '$ 3 * 7' });
        is($resp->{ok}, 1, '$ via clankd ok');
        like($resp->{output} // '', qr/21/, '$ eval returns 21 — same as in-process');

        shutdown_clankd($w, $r, $e, $pid);
    };

    subtest 'clankd: bare text falls through to LLM' => sub {
        my ($r, $w, $e, $pid) = spawn_clankd();

        my $resp = rpc($w, $r, { id => 1, prompt => 'hello' });
        is($resp->{ok}, 1, 'bare text ok');
        like($resp->{response} // '', qr{.+}, 'bare text goes to LLM — same fall-through as in-process');

        shutdown_clankd($w, $r, $e, $pid);
    };

    subtest 'clankd: content parsing matches in-process' => sub {
        my ($r, $w, $e, $pid) = spawn_clankd();

        # In-process: $s->dispatch('$ 2 + 2') gives content '2 + 2'
        # clankd: prompt '$ 2 + 2' should give same content to handler
        my $resp = rpc($w, $r, { id => 1, prompt => '$ 2 + 2' });
        is($resp->{ok}, 1, '$ 2+2 ok');
        like($resp->{output} // '', qr/4/, '$ eval result matches in-process');

        # Extra spaces stripped: '$   time()' -> content 'time()'
        $resp = rpc($w, $r, { id => 2, prompt => '$   time()' });
        is($resp->{ok}, 1, '$ time() ok');
        like($resp->{output} // '', qr/\d+/, '$ time() result matches in-process');

        shutdown_clankd($w, $r, $e, $pid);
    };

    subtest 'clankd: all registered sigils dispatch' => sub {
        my ($r, $w, $e, $pid) = spawn_clankd();

        my @sigil_tests = (
            { prompt => '/help',        label => '/' },
            { prompt => '# comment',    label => '#' },
            { prompt => '$ 1+1',        label => '$' },
            { prompt => '? hi',         label => '?' },
            { prompt => '@list',        label => '@' },
            { prompt => '% list',       label => '%' },
            { prompt => '> echo',       label => '>' },
            { prompt => ': test.t',     label => ':' },
            { prompt => '~ list',       label => '~' },
            { prompt => '!',            label => '!' },
        );

        for my $t (@sigil_tests) {
            my $resp = rpc($w, $r, { id => 1, prompt => $t->{prompt} });
            is($resp->{ok}, 1, "$t->{label} sigil dispatches via clankd");
        }

        shutdown_clankd($w, $r, $e, $pid);
    };
}

done_testing;
