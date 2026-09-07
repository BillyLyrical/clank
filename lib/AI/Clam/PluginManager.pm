# Wit discovery and loading (docs/ROADMAP.md §5).
# A broken wit warns and is skipped; the harness always runs.
#
# Two wit layouts are supported:
#   * Perl modules:  <dir>/lib/AI/Clam/Wit/<Name>.pm or <dir>/<file>.pm, with a
#     register($api) method (see wits.example/hello).
#   * Declarative decks (clam-old format): directories of .wit files — TOML
#     metadata + embedded Perl source — optionally grouped into subdirs and
#     described by a deck.toml manifest.  Loaded via AI::Clam::Wit::Loader; each
#     .wit becomes an LLM-callable tool plus dispatch/bus entries.  A deck may
#     also ship its own library modules under <dir>/lib (e.g. the logic deck
#     ships AI::Clam::Logic/AI::Clam::Rules); lib/ is added to @INC before any .wit in
#     the deck compiles, since wit sources compile at load time.
package AI::Clam::PluginManager;
use strict;
use warnings;
use AI::Clam::Wit::API;      # direct dependency: load_dir constructs one per wit
use AI::Clam::Wit::Dispatch;

sub new {
    my ($class, %o) = @_;
    my $self = bless { wits => [], apis => {}, errors => [], skipped => [], undocumented => [], dwits => {} }, $class;
    # The dispatcher shares the dwits hash so late registrations are visible.
    $self->{dispatch} = AI::Clam::Wit::Dispatch->new(wits => $self->{dwits});
    return $self;
}

# Read a unit's manifest (deck.toml or wit.toml). Returns ($meta, $path);
# $meta is undef when the dir has no manifest. Parse failures are recorded as
# errors and also yield undef — a broken manifest must not kill the load.
sub _read_manifest {
    my ($self, $dir) = @_;
    for my $mf (qw(deck.toml wit.toml)) {
        next unless -f "$dir/$mf";
        open my $fh, '<', "$dir/$mf" or do { push @{ $self->{errors} }, "$dir: cannot read $mf: $!"; return (undef, undef) };
        my $content = do { local $/; <$fh> };
        close $fh;
        require AI::Clam::Wit::File;
        my $meta = eval { AI::Clam::Wit::File::parse_toml($content) };
        if ($@) { push @{ $self->{errors} }, "$dir: unparseable $mf: $@"; return (undef, undef); }
        return ($meta, "$dir/$mf");
    }
    return (undef, undef);
}

# PATH lookup for requires_bin — same rule as AI::Clam::Wit::Loader::_have_bin.
sub _have_bin {
    my ($bin) = @_;
    return 1 if -x $bin && $bin =~ m{[/\\]};   # absolute path
    for my $dir (split /:/, ($ENV{PATH} // '')) {
        next unless length $dir;
        return 1 if -x "$dir/$bin";
    }
    return 0;
}

# Dependency gate from a manifest's requires_perl/requires_bin. Returns 1 when
# the unit may load, 0 when it was recorded in ->skipped with an actionable note.
sub _check_manifest_deps {
    my ($self, $name, $meta) = @_;
    return 1 unless $meta;
    for my $mod (@{ $meta->{requires_perl} // [] }) {
        eval { (my $f = $mod) =~ s{::}{/}g; require "$f.pm"; 1 } or do {
            push @{ $self->{skipped} }, "$name: missing Perl module $mod (fix: cpanm $mod)";
            warn "[wits] $name: skipped — missing Perl module $mod (fix: cpanm $mod)\n";
            return 0;
        };
    }
    for my $bin (@{ $meta->{requires_bin} // [] }) {
        unless (_have_bin($bin)) {
            push @{ $self->{skipped} }, "$name: missing binary $bin (fix: install '$bin')";
            warn "[wits] $name: skipped — missing binary $bin\n";
            return 0;
        }
    }
    return 1;
}

# Namespace discipline (docs/Wits.md §4): every .pm a unit ships must live under
# one of its allowed namespaces — otherwise two units whose lib/ dirs land on
# @INC could shadow each other's modules.  Returns offending paths relative to
# $dir (empty list = compliant).
#   namespaces => [ 'AI::Clam::Logic', ... ]  package prefixes the unit may ship
#   top_level_only => 1                   single-file module wits: .pm files
#                                         only at the unit root, never nested
sub check_namespaces {
    my ($class_or_self, $dir, %o) = @_;
    require File::Find;
    my @allowed = @{ $o{namespaces} // [] };
    my $top_level_only = $o{top_level_only};
    my %ok;
    for my $ns (@allowed) { (my $p = $ns) =~ s{::}{/}g; $ok{$p} = 1; }   # path prefixes
    my @bad;
    for my $base (grep { -d "$dir/$_" } ($top_level_only ? ('.') : ('lib'))) {
        File::Find::find({ no_chdir => 1, wanted => sub {
            return unless /\.pm$/ && -f $_;
            (my $rel = $File::Find::name) =~ s{^\Q$dir/$base\E/?}{};
            if ($top_level_only) {
                push @bad, $rel if index($rel, '/') >= 0;   # nested .pm in a single-file wit
                return;
            }
            my $fine = grep { $rel eq "$_.pm" || index($rel, "$_/") == 0 } keys %ok;
            push @bad, "lib/$rel" unless $fine;
        }}, "$dir/$base");
    }
    return sort @bad;
}

# Refuse to load a unit whose lib/ ships modules outside its declared
# namespaces.  Returns 1 when compliant (or nothing to check), 0 after
# recording the error.  Must run BEFORE the unit's lib/ hits @INC.
sub _enforce_namespaces {
    my ($self, $name, $dir, %o) = @_;
    return 1 unless -d "$dir/lib" || $o{top_level_only};
    my @bad = check_namespaces($self, $dir, %o);
    if (@bad) {
        push @{ $self->{errors} }, "$name: modules outside declared namespace: @bad";
        warn "[wits] $name: refusing to load — undeclared modules: @bad (declare namespace=[...] in the manifest)\n";
        return 0;
    }
    return 1;
}

# Discovery roots in priority order:
#   1. CLAM_WITS_PATH (colon list)   2. ./.clam/wits (project)
#   3. <clam home>/wits (user; CLAM_HOME or ~/.clam — AI::Clam::Util::clam_home)
#   4. explicit -w/--wit paths
sub discover_roots {
    my ($self, %o) = @_;
    require AI::Clam::Util;
    my @roots;
    push @roots, split /:/, $ENV{CLAM_WITS_PATH} if defined $ENV{CLAM_WITS_PATH} && length $ENV{CLAM_WITS_PATH};
    push @roots, '.clam/wits';
    push @roots, AI::Clam::Util::clam_home() . '/wits';
    push @roots, @{ $o{extra_paths} // [] };
    return grep { length } @roots;
}

# A root yields wit dirs: the root itself (if it is a unit), else each subdir
# that contains lib/, a .pm file, or .wit files. Always returns an arrayref
# (possibly empty).
# NOTE: called as a method ($self->_wit_dirs($root)) — $self must be consumed.
sub _wit_dirs {
    my ($self, $root) = @_;
    return [] unless -d $root;
    # The root is itself a unit when it carries its own manifest, lib/, or flat
    # .wit files (e.g. `clam -w decks/logic`).  Deliberately NOT the one-level-
    # down grouping check: at a discovery root, subdirs are units — a deck with
    # a flat .wit file must not make its whole parent root look like one deck.
    if (-f "$root/deck.toml" || -f "$root/wit.toml" || -d "$root/lib") { return [$root] }
    opendir(my $dh0, $root) or return [];
    my @flat = grep { !-d "$root/$_" && $_ =~ /\.wit$/ } readdir($dh0);
    closedir $dh0;
    return [$root] if @flat;

    opendir(my $dh, $root) or return [];
    my @dirs = grep { !/^\./ && -d "$root/$_" } readdir($dh);
    closedir $dh;
    # NOTE: paths must be root-relative — a bare $_ is resolved against CWD.
    my @filtered = grep { -d "$root/$_/lib" || _has_pm("$root/$_") || _has_wit("$root/$_") } @dirs;
    return [ map { "$root/$_" } sort @filtered ];
}

sub _has_pm {
    my ($d) = @_;
    opendir(my $dh, $d) or return 0;
    my @f = grep { /\.pm$/ && !-d "$d/$_" } readdir($dh);
    closedir $dh;
    return @f ? 1 : 0;
}

# True if the dir (or one level down — grouped decks keep their old subdir,
# e.g. logic/deduction/*.wit) contains .wit files.
sub _has_wit {
    my ($d) = @_;
    return 0 unless -d $d;
    opendir(my $dh, $d) or return 0;
    my @entries = grep { $_ !~ /^\./ } readdir($dh);
    closedir $dh;
    for my $e (@entries) {
        return 1 if -f "$d/$e" && $e =~ /\.wit$/;      # flat deck
    }
    for my $e (@entries) {                             # grouped deck: one level down
        next unless -d "$d/$e";
        opendir(my $dh2, "$d/$e") or next;
        my @w = grep { /\.wit$/ && !-d "$d/$e/$_" } readdir($dh2);
        closedir $dh2;
        return 1 if @w;
    }
    return 0;
}

sub _list_pm {
    my ($d) = @_;
    opendir(my $dh, $d) or return ();
    my @f = grep { /\.pm$/ && !-d "$d/$_" } readdir($dh);
    closedir $dh;
    return sort @f;
}

# Extract the declared package name from a single-file wit.
sub _pkg_from_file {
    my ($f) = @_;
    open my $fh, '<', $f or return undef;
    while (my $l = <$fh>) {
        if ($l =~ /^\s*package\s+([\w:]+)\s*;/) { close $fh; return $1 }
    }
    close $fh;
    return undef;
}

# Load every wit under the discovery roots. Returns loaded wit records.
sub load_all {
    my ($self, %o) = @_;
    for my $root ($self->discover_roots(%o)) {
        for my $dir (@{ $self->_wit_dirs($root) }) {
            $self->load_dir($dir);
        }
    }
    return @{ $self->{wits} };
}

# Load one wit directory. Layouts (checked in this order):
#   <dir>/**/*.wit                 declarative deck — even when it also ships
#                                  lib/ with its own engine modules (logic deck)
#   <dir>/lib/AI/Clam/Wit/<Name>.pm    module wit (standard; first module wins)
#   <dir>/<file>.pm                 single-file module wit (package from source)
sub load_dir {
    my ($self, $dir) = @_;
    (my $name = $dir) =~ s{.*/}{};

    # .wit files make a dir a declarative deck — layout priority is by content,
    # not by the presence of lib/.  A deck may ship its own library modules
    # under lib/ (declared via the manifest's namespace field; enforced at load
    # time — see docs/Wits.md).  Wit sources compile at load time, so lib/ must
    # be on @INC before any .wit in the deck compiles.
    if (_has_wit($dir)) {
        # Discoverability check (docs/Wits.md §3): decks must declare about +
        # usage.  Missing fields don't block loading — they flag the deck as
        # undocumented so `wits list` and install can call it out.
        my ($meta) = _read_manifest($self, $dir);
        unless ($meta && length($meta->{about} // '') && length($meta->{usage} // '')) {
            push @{ $self->{undocumented} }, $name;
            warn "[wits] deck $name: manifest missing about/usage (docs/Wits.md §3)\n";
        }
        # Namespace discipline BEFORE lib/ hits @INC.  A deck declares which
        # namespaces its engine modules may occupy (deck.toml namespace=[...]).
        my @ns = ref($meta->{namespace} // undef) eq 'ARRAY' ? @{ $meta->{namespace} } : ();
        return unless _enforce_namespaces($self, $name, $dir, namespaces => \@ns);
        unshift @INC, "$dir/lib" if -d "$dir/lib";
        require AI::Clam::Wit::Loader;
        my $api = AI::Clam::Wit::API->new(
            bus => $self->{bus}, store => $self->{store}, session => $self->{session},
            ui => $self->{ui}, wit_name => $name,
        );
        my @records = @{ AI::Clam::Wit::Loader->load_dir($self, $api, $dir) };
        push @{ $self->{wits} }, { name => $name, pkg => 'AI::Clam::Wit::File', dir => $dir, wit => undef, api => $api, meta => $meta, state => 'active' };
        $self->{apis}{$name} = $api;
        warn "[wits] deck $name: ", scalar(@records), " wits loaded from $dir\n" if @records && $ENV{CLAM_DEBUG};
        return;
    }

    my ($pkg, $file);
    if (-d "$dir/lib") {
        # User wits live in Clam/Wits/, harness infrastructure in Clam/Wit/
        my $wits_dir = -d "$dir/lib/AI/Clam/Wits" ? "$dir/lib/AI/Clam/Wits" : "$dir/lib/AI/Clam/Wit";
        my @mods;
        if (-d $wits_dir) {
            opendir(my $dh, $wits_dir);
            @mods = grep { /\.pm$/ } readdir($dh);
            closedir $dh;
        }
        unless (@mods) {
            push @{ $self->{errors} }, "$dir: no lib/AI/Clam/Wits/*.pm or lib/AI/Clam/Wit/*.pm";
            warn "[wits] $dir: no wit modules found, skipping\n";
            return;
        }
        (my $mod = shift @mods) =~ s{\.pm$}{};
        ($pkg, $file) = ("AI::Clam::Wits::$mod", "$wits_dir/$mod.pm");
        # If module is in Clam/Wit/ (harness infrastructure), use that namespace
        if ($wits_dir =~ m{/Clam/Wit$}) {
            ($pkg, $file) = ("AI::Clam::Wit::$mod", "$wits_dir/$mod.pm");
        }
        # Namespace discipline BEFORE lib/ hits @INC: a module wit may only
        # ship its own package (the wit + helpers under it).
        return unless _enforce_namespaces($self, $name, $dir, namespaces => [$pkg]);
        unshift @INC, "$dir/lib";
    } elsif (my @pms = _list_pm($dir)) {
        ($file, $pkg) = ("$dir/$pms[0]", _pkg_from_file("$dir/$pms[0]") // "AI::Clam::Wit::$name");
        # Single-file wit: the root .pm is fine; nested .pm would pollute @INC.
        return unless _enforce_namespaces($self, $name, $dir, top_level_only => 1);
        unshift @INC, $dir;
    } else {
        push @{ $self->{errors} }, "$dir: no wit modules, .pm files, or .wit files";
        return;
    }

    # wit.toml (docs/Wits.md §3): metadata + dependency gate for module wits.
    # Checked BEFORE require so a missing dep is an actionable skip note, not a
    # raw "Can't locate Foo.pm" compile die from inside the eval below.
    my ($meta) = _read_manifest($self, $dir);
    return unless _check_manifest_deps($self, $name, $meta);

    my $wit;
    eval {
        require $file;
        # can() on a never-defined package safely returns undef (no die), so this
        # single check covers both "package not defined" and "no register()".
        # (Stash access like %{ "$pkg::" } dies under strict refs in modern perl.)
        die "package $pkg not defined or has no register() method after loading $file\n"
            unless $pkg->can('register');
        $wit = $pkg->can('new') ? $pkg->new(wit_name => $name) : bless { wit_name => $name }, $pkg;
        1;
    } or do {
        my $err = "$@";
        push @{ $self->{errors} }, "$dir: $err";
        warn "[wits] failed to load $dir: $err";
        return;
    };

    # register() with a fresh API; errors here are isolated too.
    my $api = AI::Clam::Wit::API->new(
        bus => $self->{bus}, store => $self->{store}, session => $self->{session},
        ui => $self->{ui}, wit_name => $name,
    );
    eval { $wit->register($api); 1 } or do {
        my $err = "$@";
        push @{ $self->{errors} }, "$dir: register failed: $err";
        warn "[wits] $name: register() failed: $err";
        return;
    };

    # Cross-check the in-module `our $WIT = {...}` against wit.toml
    # (docs/Wits.md §3): the manifest is truth for humans, the package var keeps
    # a bare .pm self-describing.  Mismatch is a warning, not an error.
    if ($meta) {
        my $wmeta;
        { no strict 'refs'; $wmeta = ${ "$pkg\::WIT" } if defined ${ "$pkg\::WIT" } && ref( ${ "$pkg\::WIT" } ) eq 'HASH'; }
        for my $k (qw(about usage)) {
            next unless defined($wmeta->{$k} // undef) && defined($meta->{$k} // undef);
            warn "[wits] $name: \$WIT{$k} differs from wit.toml\n" if $wmeta->{$k} ne $meta->{$k};
        }
    }

    my $rec = { name => $name, pkg => $pkg, dir => $dir, wit => $wit, api => $api, meta => $meta, state => 'active' };
    push @{ $self->{wits} }, $rec;
    $self->{apis}{$name} = $api;
    return $rec;
}

# Bind runtime objects before loading (bus/store/session/ui).
sub bind { my ($self, %o) = @_; $self->{$_} = $o{$_} for qw(bus store session ui); return $self }

# Load built-in wits that ship with the harness. These are loaded like any
# other wit (register into a fresh API) but come from the harness's own lib
# rather than discovered directories. Each module must have a register() method.
sub load_builtins {
    my ($self, @modules) = @_;
    for my $module (@modules) {
        eval {
            # require with a variable and AI::Clam::Wit::File loaded triggers a
            # Perl 5.40 path-resolution quirk — use the string-path form
            # (same as load_dir uses for .pm wits).
            (my $file = $module) =~ s{::}{/}g;
            require "$file.pm";
            my $wit = $module->can('new') ? $module->new : bless {}, $module;
            my $api = AI::Clam::Wit::API->new(
                bus => $self->{bus}, store => $self->{store},
                session => $self->{session}, ui => $self->{ui},
                wit_name => $module,
            );
            $wit->register($api);
            my $rec = {
                name => $module, pkg => $module, dir => '',
                wit => $wit, api => $api, meta => {}, state => 'active',
            };
            push @{ $self->{wits} }, $rec;
            $self->{apis}{$module} = $api;
            1;
        } or do {
            my $err = "$@";
            push @{ $self->{errors} }, "builtin $module: $err";
            warn "[wits] failed to load builtin $module: $err";
        };
    }
    return $self;
}

# Return refs (not lists): callers dereference, and list-returning accessors
# misbehave in scalar context (e.g. `@{ $pm->errors }`).
sub wits      { $_[0]->{wits} }
sub errors    { $_[0]->{errors} }
sub skipped   { $_[0]->{skipped} }          # declarative wits skipped for missing deps
sub undocumented { $_[0]->{undocumented} }  # units whose manifest lacks about/usage
sub dwits     { $_[0]->{dwits} }            # name/trigger -> declarative wit record
sub dispatch  { $_[0]->{dispatch} }         # AI::Clam::Wit::Dispatch (the $ctx{wits} object)
sub api_for   { $_[0]->{apis}{ $_[1] } }

# All wit-registered tools as AI::Clam::Tool objects (disabled wits excluded).
sub all_tools {
    my ($self) = @_;
    require AI::Clam::Tool;
    return map { AI::Clam::Tool->new(%$_) }
           map { @{ $_->{api}->registered_tools } }
           grep { ($_->{state} // 'active') eq 'active' }
           @{ $self->{wits} };
}

# Merged slash commands: name -> {description, handler, wit} (disabled wits excluded).
sub all_commands {
    my ($self) = @_;
    my %cmds;
    for my $rec (@{ $self->{wits} }) {
        next unless ($rec->{state} // 'active') eq 'active';
        for my $name (keys %{ $rec->{api}->registered_commands }) {
            $cmds{$name} = { %{ $rec->{api}->registered_commands->{$name} }, wit => $rec->{name} };
        }
    }
    return \%cmds;
}

# ---------------------------------------------------------------------------
# Lifecycle: disable / enable (docs/Wits.md §5).  Disable runs every reverse
# operation the wit registered (bus subscriptions) and hides its tools and
# commands.  Enable re-registers into a FRESH api — for module wits that is
# register() on the still-compiled object; for declarative decks it replays
# every .wit in the deck.  Tools of the CURRENT session are snapshotted at
# start_session, so tool changes take effect from the next session (/new);
# hooks stop and restart immediately.
# ---------------------------------------------------------------------------
sub wit_state {
    my ($self, $name) = @_;
    for my $r (@{ $self->{wits} }) { return $r->{state} // 'active' if $r->{name} eq $name }
    return undef;
}

sub _find_rec {
    my ($self, $name) = @_;
    for my $r (@{ $self->{wits} }) { return $r if $r->{name} eq $name }
    return undef;
}

sub disable_wit {
    my ($self, $name) = @_;
    my $rec = _find_rec($self, $name);
    return "no such wit: $name" unless $rec;
    return "$name is already disabled" if ($rec->{state} // 'active') eq 'disabled';
    my $n = $rec->{api}->unsubscribe_all();
    $rec->{state} = 'disabled';
    return "disabled $name — $n hook subscription(s) removed; tools/commands drop from new sessions";
}

sub enable_wit {
    my ($self, $name) = @_;
    my $rec = _find_rec($self, $name);
    return "no such wit: $name" unless $rec;
    return "$name is already active" if ($rec->{state} // 'active') eq 'active';

    # Fresh api: the old one's subscriptions were removed at disable time and
    # reusing it would double-push tools.  register() must be idempotent —
    # that is part of the wit contract (see wits.example/hello).
    my $api = AI::Clam::Wit::API->new(
        bus => $self->{bus}, store => $self->{store}, session => $self->{session},
        ui => $self->{ui}, wit_name => $name,
    );
    if ($rec->{pkg} eq 'AI::Clam::Wit::File') {
        require AI::Clam::Wit::Loader;
        my @records = @{ AI::Clam::Wit::Loader->load_dir($self, $api, $rec->{dir}) };
        return "enable failed: no wits reloaded for deck $name" unless @records;
    } else {
        eval { $rec->{wit}->register($api); 1 } or do {
            my $err = "$@";
            push @{ $self->{errors} }, "$rec->{dir}: re-register failed: $err";
            return "enable failed for $name: $err";
        };
    }
    $rec->{api}   = $api;
    $rec->{state} = 'active';
    return "enabled $name — tools/commands drop into new sessions";
}

1;
