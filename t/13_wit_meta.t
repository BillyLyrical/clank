# Wit metadata & discoverability (docs/Wits.md §3): manifest fields,
# wits.index.json rebuild/read, $WIT cross-check, module-wit dependency gate,
# undocumented flagging, and the CLI list/search surface.
use strict; use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::RealBin/../lib";
use File::Path qw(make_path remove_tree);

my $tmp = "$FindBin::RealBin/../_tmp/wit_meta";
remove_tree($tmp) if -d $tmp;
make_path($tmp);
local $ENV{HOME}      = "$tmp/home";
local $ENV{CLAM_HOME} = "$tmp/clamhome";
delete $ENV{CLAM_WITS_PATH};
chdir $tmp or die "chdir: $!";

use AI::Clam::PluginManager;

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

# beta — module wit with matching wit.toml + our $WIT
write_file("$UROOT/beta/wit.toml", <<'EOF');
name="beta"
version="1.0.0"
about="Beta wit does beta things"
usage="Load when you need beta."
EOF
write_file("$UROOT/beta/lib/AI/Clam/Wit/Beta.pm", <<'EOF');
package AI::Clam::Wit::Beta;
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
write_file("$UROOT/deps/lib/AI/Clam/Wit/Deps.pm", <<'EOF');
package AI::Clam::Wit::Deps;
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
write_file("$UROOT/mismatch/lib/AI/Clam/Wit/Mismatch.pm", <<'EOF');
package AI::Clam::Wit::Mismatch;
use strict; use warnings;
our $WIT = { about => 'Module says B', usage => 'Load when you need mismatch.' };
sub register { }
1;
EOF

# ---------------------------------------------------------------------------
# 1. PluginManager load: undocumented flag, dep gate, $WIT cross-check
# ---------------------------------------------------------------------------
my @warnings;
local $SIG{__WARN__} = sub { push @warnings, $_[0] };

my $pm = AI::Clam::PluginManager->new;
$pm->bind(bus => undef, store => undef, session => undef);
my @wits = $pm->load_all();

is(scalar(@wits), 3, 'three units loaded (deps skipped)');
is_deeply([ @{ $pm->undocumented } ], ['gamma'], 'deck without about/usage flagged undocumented');
like(join("\n", @{ $pm->skipped }), qr/deps: missing Perl module No::Such::Module::ClamTest13 \(fix: cpanm/,
    'dep gate produces actionable skip note');
my @pkgs = map { $_->{pkg} // '' } @wits;
ok(!grep { /AI::Clam::Wit::Deps/ } @pkgs, 'skipped unit not loaded');

my $tools   = [ map { $_->{name} } @{ $pm->api_for('beta')->registered_tools } ];
is($tools->[0], 'beta_tool', 'module wit tool registered');

like(join("\n", @warnings), qr/mismatch: \$WIT\{about\} differs from wit\.toml/, '$WIT/manifest mismatch warns');
unlike(join("\n", @warnings), qr/beta: \$WIT/, 'matching $WIT does not warn');

# ---------------------------------------------------------------------------
# 2. Namespace discipline (docs/Wits.md §4) — isolated root via CLAM_WITS_PATH
# ---------------------------------------------------------------------------
{
    local $ENV{CLAM_WITS_PATH} = "$tmp/nsroot";

    # nsbad — deck with lib/ but no namespace declaration
    write_file("$tmp/nsroot/nsbad/deck.toml", "name=\"nsbad\"\nversion=\"0.1.0\"\nabout=\"x\"\nusage=\"y\"\nwits=[\"b.one\"]\n");
    write_file("$tmp/nsroot/nsbad/b/one.wit", "name=one\ndescription=x\nsource = <<'PERL'\nreturn { ok => 1 };\nPERL\n");
    write_file("$tmp/nsroot/nsbad/lib/AI/Clam/Stray.pm", "package AI::Clam::Stray;\n1;\n");

    # nsgood — deck declaring its namespace; lib/ fully compliant
    write_file("$tmp/nsroot/nsgood/deck.toml", "name=\"nsgood\"\nversion=\"0.1.0\"\nabout=\"x\"\nusage=\"y\"\nnamespace=[\"AI::Clam::NsGood\"]\nwits=[\"g.one\"]\n");
    write_file("$tmp/nsroot/nsgood/g/one.wit", "name=one\ndescription=x\nsource = <<'PERL'\nreturn { ok => 1 };\nPERL\n");
    write_file("$tmp/nsroot/nsgood/lib/AI/Clam/NsGood.pm", "package AI::Clam::NsGood;\n1;\n");
    write_file("$tmp/nsroot/nsgood/lib/AI/Clam/NsGood/Sub.pm", "package AI::Clam::NsGood::Sub;\n1;\n");

    # modbad — module wit shipping a module outside its own package
    write_file("$tmp/nsroot/modbad/wit.toml", "name=\"modbad\"\nversion=\"0.1.0\"\nabout=\"x\"\nusage=\"y\"\n");
    write_file("$tmp/nsroot/modbad/lib/AI/Clam/Wit/Modbad.pm", "package AI::Clam::Wit::Modbad;\nsub register { }\n1;\n");
    write_file("$tmp/nsroot/modbad/lib/AI/Clam/Stray2.pm", "package AI::Clam::Stray2;\n1;\n");

    my $pm3 = AI::Clam::PluginManager->new;
    $pm3->bind(bus => undef, store => undef, session => undef);
    my @w3 = $pm3->load_all();
    my %names3 = map { $_->{name} => 1 } @w3;
    ok($names3{nsgood}, 'compliant deck loaded');
    ok(!$names3{nsbad} && !$names3{modbad}, 'non-compliant units not loaded');
    like(join("\n", @{ $pm3->errors }), qr/nsbad: modules outside declared namespace: lib\/AI\/Clam\/Stray\.pm/,
        'undeclared deck module refused and named');
    like(join("\n", @{ $pm3->errors }), qr/modbad: modules outside declared namespace: lib\/AI\/Clam\/Stray2\.pm/,
        'module wit shipping a foreign module refused');
}

done_testing();
