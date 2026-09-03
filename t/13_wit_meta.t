# Wit metadata & discoverability (docs/Wits.md §3): manifest fields,
# wits.index.json rebuild/read, $WIT cross-check, module-wit dependency gate,
# undocumented flagging, and the CLI list/search surface.
use strict; use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::RealBin/../lib";
use File::Temp qw(tempdir);
use File::Path qw(make_path);

my $tmp = tempdir(CLEANUP => 1);
local $ENV{HOME}      = "$tmp/home";
local $ENV{CLAM_HOME} = "$tmp/clamhome";
delete $ENV{CLAM_WITS_PATH};
chdir $tmp or die "chdir: $!";

use Clam::WitIndex;
use Clam::PluginManager;

# ---------------------------------------------------------------------------
# Fixtures.  User root = $CLAM_HOME/wits, project root = ./.clam/wits (cwd).
# ---------------------------------------------------------------------------
my $UROOT = "$ENV{CLAM_HOME}/wits";
my $PROOT = ".clam/wits";

sub write_file {
    my ($path, $content) = @_;
    make_path((do { my $d = $path; $d =~ s{/[^/]+$}{}; $d }));
    open my $fh, '>', $path or die "cannot write $path: $!";
    print {$fh} $content;
    close $fh;
}

# alpha — declarative deck, full manifest
write_file("$UROOT/alpha/deck.toml", <<'EOF');
name="alpha"
version="0.2.0"
about="Alpha deck does alpha things"
usage="Load when you need alpha."
wits=["group.one"]
EOF
write_file("$UROOT/alpha/group/one.wit", <<'EOF');
name="one"
description="does one thing"
source = <<'PERL'
my ($self, $input, %ctx) = @_;
return { ok => 1 };
PERL
EOF

# beta — module wit with matching wit.toml + our $WIT
write_file("$UROOT/beta/wit.toml", <<'EOF');
name="beta"
version="1.0.0"
about="Beta wit does beta things"
usage="Load when you need beta."
EOF
write_file("$UROOT/beta/lib/Clam/Wit/Beta.pm", <<'EOF');
package Clam::Wit::Beta;
use strict; use warnings;
our $WIT = { about => 'Beta wit does beta things', usage => 'Load when you need beta.' };
sub register {
    my ($self, $api) = @_;
    $api->register_tool(name => 'beta_tool', description => 'x',
        parameters => { type => 'object' }, execute => sub { 'ok' });
}
1;
EOF

# gamma — deck manifest missing about/usage (undocumented)
write_file("$UROOT/gamma/deck.toml", "name=\"gamma\"\nversion=\"0.1.0\"\ndescription=\"no discoverability fields\"\n");
write_file("$UROOT/gamma/plain.wit", <<'EOF');
name="plain"
description="a plain wit"
source = <<'PERL'
my ($self, $input, %ctx) = @_;
return { ok => 1 };
PERL
EOF

# deps — module wit whose manifest declares a missing Perl dependency
write_file("$UROOT/deps/wit.toml", <<'EOF');
name="deps"
version="0.1.0"
about="Wit with an unsatisfied dependency"
usage="Should be skipped with an actionable note."
requires_perl=["No::Such::Module::ClamTest13"]
EOF
write_file("$UROOT/deps/lib/Clam/Wit/Deps.pm", <<'EOF');
package Clam::Wit::Deps;
use strict; use warnings;
sub register { }
1;
EOF

# mismatch — module wit whose $WIT disagrees with wit.toml
write_file("$UROOT/mismatch/wit.toml", <<'EOF');
name="mismatch"
version="0.1.0"
about="Manifest says A"
usage="Load when you need mismatch."
EOF
write_file("$UROOT/mismatch/lib/Clam/Wit/Mismatch.pm", <<'EOF');
package Clam::Wit::Mismatch;
use strict; use warnings;
our $WIT = { about => 'Module says B', usage => 'Load when you need mismatch.' };
sub register { }
1;
EOF

# delta — project-root deck (full manifest)
write_file("$PROOT/delta/deck.toml", <<'EOF');
name="delta"
version="0.3.0"
about="Delta deck lives in the project root"
usage="Load when you need delta."
wits=["d.one"]
EOF
write_file("$PROOT/delta/d/one.wit", <<'EOF');
name="done"
description="does one thing"
source = <<'PERL'
my ($self, $input, %ctx) = @_;
return { ok => 1 };
PERL
EOF

# ---------------------------------------------------------------------------
# 1. scan_dir / rebuild / read
# ---------------------------------------------------------------------------
my $entry = Clam::WitIndex->scan_dir("$UROOT/alpha");
is($entry->{about}, 'Alpha deck does alpha things', 'scan_dir reads about from deck.toml');
is(Clam::WitIndex->scan_dir("$tmp/no-such-dir"), undef, 'no manifest -> undef');

my $idx = Clam::WitIndex->rebuild();
ok(exists $idx->{alpha},  'user-root deck indexed');
ok(exists $idx->{delta},  'project-root deck indexed');
is($idx->{beta}{version}, '1.0.0', 'module wit version from wit.toml');
is($idx->{gamma}{about}, '(undocumented)', 'missing about flagged in index');
ok(-f Clam::WitIndex->path(), 'index file written to clam home');

my $reread = Clam::WitIndex->read();
is_deeply([ sort keys %$reread ], [ qw(alpha beta delta deps gamma mismatch) ], 'round-trip: all six units');

# ---------------------------------------------------------------------------
# 2. PluginManager load: undocumented flag, dep gate, $WIT cross-check
# ---------------------------------------------------------------------------
my @warnings;
local $SIG{__WARN__} = sub { push @warnings, $_[0] };

my $pm = Clam::PluginManager->new;
$pm->bind(bus => undef, store => undef, session => undef);
my @wits = $pm->load_all();

is(scalar(@wits), 5, 'five units loaded (deps skipped)');
is_deeply([ @{ $pm->undocumented } ], ['gamma'], 'deck without about/usage flagged undocumented');
like(join("\n", @{ $pm->skipped }), qr/deps: missing Perl module No::Such::Module::ClamTest13 \(fix: cpanm/,
    'dep gate produces actionable skip note');
my @pkgs = map { $_->{pkg} // '' } @wits;
ok(!grep { /Clam::Wit::Deps/ } @pkgs, 'skipped unit not loaded');

my $tools   = [ map { $_->{name} } @{ $pm->api_for('beta')->registered_tools } ];
is($tools->[0], 'beta_tool', 'module wit tool registered');

like(join("\n", @warnings), qr/mismatch: \$WIT\{about\} differs from wit\.toml/, '$WIT/manifest mismatch warns');
unlike(join("\n", @warnings), qr/beta: \$WIT/, 'matching $WIT does not warn');

# ---------------------------------------------------------------------------
# 3. CLI surface (subprocess; inherits HOME/CLAM_HOME/cwd)
# ---------------------------------------------------------------------------
my $clam = "$FindBin::RealBin/../bin/clam";

my $out = `$^X "$clam" wits search alpha 2>&1`;
is($? >> 8, 0, 'search hit exits 0');
like($out, qr/alpha\s+\[about\] Alpha deck does alpha things/, 'search prints name + field + text');

$out = `$^X "$clam" wits search zzznotfound 2>&1`;
isnt($? >> 8, 0, 'no match exits non-zero (grep convention)');
like($out, qr/no wits match/, 'no-match message');

$out = `$^X "$clam" wits list 2>&1`;
is($? >> 8, 0, 'list exits 0');
like($out, qr/alpha\s+Alpha deck does alpha things/m, 'list shows about text');
like($out, qr/delta\s+Delta deck lives in the project root/m, 'list covers project root too');

# ---------------------------------------------------------------------------
# 4. Namespace discipline (docs/Wits.md §4) — isolated root via CLAM_WITS_PATH
# ---------------------------------------------------------------------------
{
    local $ENV{CLAM_WITS_PATH} = "$tmp/nsroot";

    # nsbad — deck with lib/ but no namespace declaration
    write_file("$tmp/nsroot/nsbad/deck.toml", "name=\"nsbad\"\nversion=\"0.1.0\"\nabout=\"x\"\nusage=\"y\"\nwits=[\"b.one\"]\n");
    write_file("$tmp/nsroot/nsbad/b/one.wit", "name=one\ndescription=x\nsource = <<'PERL'\nreturn { ok => 1 };\nPERL\n");
    write_file("$tmp/nsroot/nsbad/lib/Clam/Stray.pm", "package Clam::Stray;\n1;\n");

    # nsgood — deck declaring its namespace; lib/ fully compliant
    write_file("$tmp/nsroot/nsgood/deck.toml", "name=\"nsgood\"\nversion=\"0.1.0\"\nabout=\"x\"\nusage=\"y\"\nnamespace=[\"Clam::NsGood\"]\nwits=[\"g.one\"]\n");
    write_file("$tmp/nsroot/nsgood/g/one.wit", "name=one\ndescription=x\nsource = <<'PERL'\nreturn { ok => 1 };\nPERL\n");
    write_file("$tmp/nsroot/nsgood/lib/Clam/NsGood.pm", "package Clam::NsGood;\n1;\n");
    write_file("$tmp/nsroot/nsgood/lib/Clam/NsGood/Sub.pm", "package Clam::NsGood::Sub;\n1;\n");

    # modbad — module wit shipping a module outside its own package
    write_file("$tmp/nsroot/modbad/wit.toml", "name=\"modbad\"\nversion=\"0.1.0\"\nabout=\"x\"\nusage=\"y\"\n");
    write_file("$tmp/nsroot/modbad/lib/Clam/Wit/Modbad.pm", "package Clam::Wit::Modbad;\nsub register { }\n1;\n");
    write_file("$tmp/nsroot/modbad/lib/Clam/Stray2.pm", "package Clam::Stray2;\n1;\n");

    my $pm3 = Clam::PluginManager->new;
    $pm3->bind(bus => undef, store => undef, session => undef);
    my @w3 = $pm3->load_all();
    # load_all sees every root: the section-2 fixtures (alpha/beta/gamma/
    # mismatch + project-root delta) plus this isolated root.  nsbad and
    # modbad must be refused; deps was already skipped for its missing dep.
    my %names3 = map { $_->{name} => 1 } @w3;
    is(scalar(@w3), 6, 'compliant unit + section-2 fixtures load (nsbad/modbad refused)');
    ok($names3{nsgood}, 'compliant deck loaded');
    ok(!$names3{nsbad} && !$names3{modbad}, 'non-compliant units not loaded');
    like(join("\n", @{ $pm3->errors }), qr/nsbad: modules outside declared namespace: lib\/Clam\/Stray\.pm/,
        'undeclared deck module refused and named');
    like(join("\n", @{ $pm3->errors }), qr/modbad: modules outside declared namespace: lib\/Clam\/Stray2\.pm/,
        'module wit shipping a foreign module refused');
}

done_testing();
