# Deck loading and behavior (docs/DESIGN.md section 9; decks/README.md).
# Verifies that the ported clam-old wits load through PluginManager and work
# as meant: tools execute with correct outputs, inter-wit dispatch chains,
# state persists, bus agents react, and deck install works end-to-end.
use strict; use warnings;
use Test::More;
use FindBin;
use lib 'lib';
use File::Temp qw(tempdir);
use Clam::Store;
use Clam::Bus;
use Clam::Session;
use Clam::PluginManager;
use Clam::Wit::File;
use Clam::Util qw(jdecode jencode);
use JSON::PP;

my $DECKS = "$FindBin::RealBin/../decks";
my $tmp   = tempdir(CLEANUP => 1);

# isolate from real user/project wits
local $ENV{HOME} = "$tmp/home";
delete $ENV{CLAM_WITS_PATH};
chdir $tmp or die "chdir: $!";

# ===========================================================================
# 1. WitFile parser (TOML subset + heredoc source)
# ===========================================================================
my $d = Clam::Wit::File::parse_toml(<<'TOML');
name="x"
enabled=true
count=3
ratio=1.5
bare=word
esc="line\nbreak \"quoted\""
arr=["a", "b"]
multi=[
  "c",
  "d", # trailing comment
]
mline="""
para one
para two"""
[metadata]
category="test"
[[inputs]]
field="f1"
[[inputs]]
field="f2"
TOML
is($d->{name}, 'x', 'toml: basic string');
is($d->{enabled}, 1, 'toml: boolean true');
is($d->{count}, 3, 'toml: integer');
is($d->{ratio}, 1.5, 'toml: float');
is($d->{bare}, 'word', 'toml: bare word kept as string');
is($d->{esc}, "line\nbreak \"quoted\"", 'toml: escapes in basic string');
is_deeply($d->{arr}, ['a','b'], 'toml: single-line array');
is_deeply($d->{multi}, ['c','d'], 'toml: multi-line array with comment');
is($d->{mline}, "para one\npara two", 'toml: multi-line string trims leading newline');
is($d->{metadata}{category}, 'test', 'toml: [table] section');
is_deeply([map { $_->{field} } @{ $d->{inputs} }], ['f1','f2'], 'toml: [[array of tables]]');

my $pf = "$tmp/sample.wit";
open my $sfh, '>', $pf or die;
print {$sfh} "#!wit/toml\nname=\"sample\"\ntype=\"rule\"\nsource = <<'PERL'\nmy (\$self,\$input,%ctx) = \@_;\nreturn { ok => 1 };\nPERL\n";
close $sfh;
my $parsed = Clam::Wit::File->parse_file($pf);
is($parsed->{meta}{name}, 'sample', 'parse_file: metadata');
like($parsed->{source}, qr/return \{ ok => 1 \}/, 'parse_file: heredoc source extracted');

my $code = Clam::Wit::File->compile("my (\$self,\$input,%ctx) = \@_;\nreturn { n => 7 };", name => 't');
is_deeply($code->(undef, {}, ()), { n => 7 }, 'compile: closure runs with ($self,$input,%ctx)');
eval { Clam::Wit::File->compile("my (\$x = \@_; oops(", name => 'bad') };
like($@, qr/failed to compile/, 'compile: bad perl dies with clear error');

# ===========================================================================
# 2. Deck loading through PluginManager
# ===========================================================================
my $store = Clam::Store->new(path => ":memory:");
my $bus   = Clam::Bus->new(store => $store);
my $sess  = Clam::Session->new(store => $store, bus => $bus);
my $pm    = Clam::PluginManager->new;
$pm->bind(bus => $bus, store => $store, session => $sess);

my @deck_names = qw(logic critic git fs search);
my @wits = $pm->load_all(extra_paths => [ map { "$DECKS/$_" } @deck_names ]);
is(scalar(@wits), 5, 'all five decks discovered and loaded');
is_deeply($pm->errors, [], 'no load errors across all decks');

my %tools = map { $_->{name} => $_ } $pm->all_tools();
my %count = (logic => 50, critic => 12, git => 10, fs => 18, search => 9);   # sat.solve disabled in source
is(scalar(keys %tools), 99, '99 tools registered (100 wits minus disabled sat.solve)');

for my $t (qw(deduction.axiom deduction.deduce rule.greet induction.theorem
              datalog.query rule.add rule.run critic.quality git.status fs.read search.local)) {
    ok($tools{$t}, "tool present: $t");
}
ok(!$tools{'sat.solve'}, 'disabled sat.solve not registered');
ok($tools{'sat.encode'} && $tools{'sat.csp'}, 'enabled sat wits registered');

# ===========================================================================
# 3. Behavior — logic deck
# ===========================================================================
sub run_tool {
    my ($name, $args) = @_;
    die "no tool $name" unless $tools{$name};
    return $tools{$name}->run($args);
}
sub out_json { jdecode($_[0]->{output}) }

my $r = run_tool('rule.greet', { text => 'hello world' });
is($r->{isError}, 0, 'rule.greet runs');
like((out_json($r))->{greeting}, qr/Hello/i, 'rule.greet greets');

$r = run_tool('rule.detect_no_strict', { text => 'lib/Foo.pm' });
is_deeply([(out_json($r))->{found}], [0], 'detect_no_strict flags file without strict');
like((out_json($r))->{suggestion}, qr/use strict/, 'detect_no_strict suggests fix');

$r = run_tool('rule.classify_perl', { text => "use strict; my \$x = 1;" });
is((out_json($r))->{domain}, 'perl', 'classify_perl identifies perl code');
is_deeply((out_json($r))->{tags}, ['perl','code'], 'classify_perl tags');

# full deductive chain through inter-wit dispatch (deduce -> axiom/given/rule/apply/certainty/proof)
my $chain = eval { $pm->dispatch->execute('deduction.deduce', {
    axioms => [ { truth => 'All men are mortal' } ],
    givens => [ { fact  => 'Socrates is a man' } ],
    rules  => [ { if => 'is a man', then => 'Socrates is mortal', name => 'mortality' } ],
}); };
ok(!$@, "deduction.deduce chain runs: $@");
is($chain->{conclusion}, 'Socrates is mortal', 'deduction reaches conclusion');
is($chain->{valid}, 1, 'deduction marks proof valid');
cmp_ok(scalar(@{ $chain->{proof} }), '>=', 4, 'deduction records proof steps');

my $enc = out_json(run_tool('sat.encode', {
    variables => { A => [1,2], B => [1,2] },
    constraints => [{ type => 'alldiff', vars => ['A','B'] }],
}));
is($enc->{ok}, 1, 'sat.encode ok');
like($enc->{dimacs}, qr/^p cnf 4 6/, 'sat.encode: correct CNF header (4 vars, 6 clauses)');
is_deeply([sort keys %{ $enc->{var_map} }], ['A','B'], 'sat.encode var map');

if (system('which picosat >/dev/null 2>&1') == 0) {
    my $csp = out_json(run_tool('sat.csp', { preset => 'nqueens', n => 4 }));
    is($csp->{sat}, 1, 'sat.csp: 4-queens satisfiable via picosat');
    my @q = map { $csp->{solution}{"Q$_"} } 1..4;
    my %seen; @seen{@q} = ();
    is(scalar(keys %seen), 4, 'sat.csp: solution uses all columns (valid permutation)');
} else {
    skip 'picosat not installed', 2;
}

# ===========================================================================
# 4. Behavior — critic deck
# ===========================================================================
$r = run_tool('critic.quality', { text => "use strict;\nuse warnings;\nsub f {\n    return 1;\n}\n" });
my $q = out_json($r);
is($r->{isError}, 0, 'critic.quality runs');
ok(defined $q->{score} && defined $q->{grade}, 'critic.quality returns score+grade');
is(ref $q->{issues}, 'ARRAY', 'critic.quality issues is arrayref');
like(join(',', @{ $q->{strengths} // [] }), qr/uses strict/, 'critic.quality credits use strict');

# ===========================================================================
# 5. Behavior — git deck (real temp repo)
# ===========================================================================
my $repo = "$tmp/repo";
system('git', 'init', '-q', $repo) == 0 or BAIL_OUT("git init failed");
local $ENV{GIT_AUTHOR_NAME}     = 'Test';
local $ENV{GIT_AUTHOR_EMAIL}    = 't\@example.com';
local $ENV{GIT_COMMITTER_NAME}  = 'Test';
local $ENV{GIT_COMMITTER_EMAIL} = 't\@example.com';

open my $rfh, '>', "$repo/a.txt" or die; print {$rfh} "one\n"; close $rfh;
system('git', '-C', $repo, 'add', 'a.txt') == 0 or BAIL_OUT("git add failed");
system('git', '-C', $repo, 'commit', '-q', '-m', 'first') == 0 or BAIL_OUT("git commit failed");

$r = run_tool('git.status', { path => $repo });
is_deeply([(out_json($r))->{clean}], [JSON::PP::true], 'git.status: clean after commit');

open $rfh, '>', "$repo/a.txt" or die; print {$rfh} "one\ntwo\n"; close $rfh;
$r = run_tool('git.status', { path => $repo });
is_deeply([(out_json($r))->{clean}], [JSON::PP::false], 'git.status: dirty after edit');
ok(scalar(@{ (out_json($r))->{modified} }) >= 1, 'git.status lists modified file');

$r = run_tool('git.log', { path => $repo });
is($r->{isError}, 0, 'git.log runs');
like($r->{output}, qr/first/, 'git.log shows commit subject');

# ===========================================================================
# 6. Behavior — fs deck (roundtrips in temp dir)
# ===========================================================================
my $wd = "$tmp/fs";
mkdir $wd or die;
$r = run_tool('fs.write', { path => "$wd/hello.txt", content => "deck smoke test" });
is((out_json($r))->{ok}, 1, 'fs.write ok');
is(-s "$wd/hello.txt", 15, 'fs.write created file on disk');

$r = run_tool('fs.read', { path => "$wd/hello.txt" });
is((out_json($r))->{content}, "deck smoke test", 'fs.read roundtrip content');

open my $l2, '>', "$wd/other.txt" or die; print {$l2} "needle in haystack\n"; close $l2;
$r = run_tool('fs.search', { path => $wd, contains => 'needle' });
my $fsr = out_json($r);
is($fsr->{count}, 1, 'fs.search finds exactly one file by content');
like(join(',', map { $_->{path} } @{ $fsr->{files} }), qr/other\.txt/, 'fs.search result names the file');

# ===========================================================================
# 7. Behavior — search deck (bus-based local search + state persistence)
# ===========================================================================
# A mock "wiki" source answers the bus topic search.local queries.
$bus->subscribe('wiki.search', sub {
    my ($ev) = @_;
    return { entries => [ { title => 'Perl', content => $ev->{payload}{query} } ] };
}, name => 'mock.wiki');

$r = run_tool('search.local', { query => 'perl', sources => ['wiki'] });
my $sl = out_json($r);
is($r->{isError}, 0, 'search.local runs');
ok(ref $sl->{results} eq 'ARRAY' && @{ $sl->{results} } >= 1, 'search.local collects bus source results');

# stateful wit: configure persists api_key into store kv (survives across calls)
$r = run_tool('search.google', { action => 'configure', api_key => 'k-123' });
is((out_json($r))->{has_key}, 1, 'search.google configure reports key set');
my $st = $store->kv_get('wit_state.search.google');
is(ref $st eq 'HASH' ? $st->{api_key} : undef, 'k-123', 'stateful wit state persisted to store kv');

# ===========================================================================
# 8. Bus agent: subscribed wit reacts and publishes its result
# ===========================================================================
$bus->publish('search.whatever', { action => 'register', provider => 'mockprov' });
my $evs = $store->query_events(topic => 'search.results', limit => 5);
ok(scalar(@$evs) >= 1, 'subscribed wit published result to search.results');
like(jencode($evs->[0]{payload}), qr/mockprov/, 'bus agent result carries handler output');

# ===========================================================================
# 9. Deck install via CLI (separate HOME, real bin/clam)
# ===========================================================================
my $bin = "$FindBin::RealBin/../bin/clam";
my @out = `"$^X" "$bin" wits install "$DECKS/git" 2>&1`;
is($? >> 8, 0, 'clam wits install exits 0');
like(join('', @out), qr/deck: git/, 'install prints deck manifest info');
ok(-f "$tmp/home/.clam/wits/git/deck.toml", 'installed deck has manifest');
ok(-d "$tmp/home/.clam/wits/git/git" && -f "$tmp/home/.clam/wits/git/git/status.wit", 'installed deck keeps group layout');

# fresh manager discovers the installed deck from the user root (no extra_paths)
my $pm2 = Clam::PluginManager->new;
$pm2->bind(bus => $bus, store => $store, session => $sess);
my @w2 = $pm2->load_all();
is_deeply($pm2->errors, [], 'installed deck loads without errors');
my %t2 = map { $_->{name} => 1 } $pm2->all_tools();
ok($t2{'git.status'} && $t2{'git.log'}, 'installed git tools available after install');

# reinstall is refused
my @out2 = `"$^X" "$bin" wits install "$DECKS/git" 2>&1`;
like(join('', @out2), qr/already installed/, 'reinstall refused');

done_testing();
