# Wit discovery and loading (docs/DESIGN.md section 9).
# A broken wit warns and is skipped; the harness always runs.
#
# Two wit layouts are supported:
#   * Perl modules:  <dir>/lib/Clam/Wit/<Name>.pm or <dir>/<file>.pm, with a
#     register($api) method (see wits.example/hello).
#   * Declarative decks (clam-old format): directories of .wit files — TOML
#     metadata + embedded Perl source — optionally grouped into subdirs and
#     described by a deck.toml manifest.  Loaded via Clam::WitLoader; each
#     .wit becomes an LLM-callable tool plus dispatch/bus entries.
package Clam::PluginManager;
use strict;
use warnings;
use Clam::WitAPI;      # direct dependency: load_dir constructs one per wit
use Clam::WitDispatch;

sub new {
    my ($class, %o) = @_;
    my $self = bless { wits => [], apis => {}, errors => [], skipped => [], dwits => {} }, $class;
    # The dispatcher shares the dwits hash so late registrations are visible.
    $self->{dispatch} = Clam::WitDispatch->new(wits => $self->{dwits});
    return $self;
}

# Discovery roots in priority order:
#   1. CLAM_WITS_PATH (colon list)   2. ./.clam/wits (project)
#   3. ~/.clam/wits (user)           4. explicit -w/--wit paths
sub discover_roots {
    my ($self, %o) = @_;
    my @roots;
    push @roots, split /:/, $ENV{CLAM_WITS_PATH} if defined $ENV{CLAM_WITS_PATH} && length $ENV{CLAM_WITS_PATH};
    push @roots, '.clam/wits';
    push @roots, "$ENV{HOME}/.clam/wits" if defined $ENV{HOME};
    push @roots, @{ $o{extra_paths} // [] };
    return grep { length } @roots;
}

# A root yields wit dirs: the root itself (if it has lib/ or .wit files), else
# each subdir that contains lib/, a .pm file, or .wit files. Always returns an
# arrayref (possibly empty).
# NOTE: called as a method ($self->_wit_dirs($root)) — $self must be consumed.
sub _wit_dirs {
    my ($self, $root) = @_;
    return [] unless -d $root;
    return [$root] if -d "$root/lib" || _has_wit($root);
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

# Load one wit directory. Layouts:
#   <dir>/lib/Clam/Wit/<Name>.pm     (standard; first module wins)
#   <dir>/<file>.pm                  (single-file; package read from source)
sub load_dir {
    my ($self, $dir) = @_;
    (my $name = $dir) =~ s{.*/}{};

    my ($pkg, $file);
    if (-d "$dir/lib") {
        unshift @INC, "$dir/lib";
        my $wits_dir = "$dir/lib/Clam/Wit";
        my @mods;
        if (-d $wits_dir) {
            opendir(my $dh, $wits_dir);
            @mods = grep { /\.pm$/ } readdir($dh);
            closedir $dh;
        }
        unless (@mods) {
            push @{ $self->{errors} }, "$dir: no lib/Clam/Wit/*.pm";
            warn "[wits] $dir: no wit modules found, skipping\n";
            return;
        }
        (my $mod = shift @mods) =~ s{\.pm$}{};
        ($pkg, $file) = ("Clam::Wit::$mod", "$wits_dir/$mod.pm");
    } elsif (my @pms = _list_pm($dir)) {
        unshift @INC, $dir;
        ($file, $pkg) = ("$dir/$pms[0]", _pkg_from_file("$dir/$pms[0]") // "Clam::Wit::$name");
    } else {
        # Declarative deck: .wit files (clam-old format), flat or grouped.
        unless (_has_wit($dir)) { push @{ $self->{errors} }, "$dir: no wit modules, .pm files, or .wit files"; return }
        require Clam::WitLoader;
        my $api = Clam::WitAPI->new(
            bus => $self->{bus}, store => $self->{store}, session => $self->{session},
            ui => $self->{ui}, wit_name => $name,
        );
        my @records = @{ Clam::WitLoader->load_dir($self, $api, $dir) };
        push @{ $self->{wits} }, { name => $name, pkg => 'Clam::WitFile', dir => $dir, wit => undef, api => $api };
        $self->{apis}{$name} = $api;
        warn "[wits] deck $name: ", scalar(@records), " wits loaded from $dir\n" if @records && $ENV{CLAM_DEBUG};
        return;
    }

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
    my $api = Clam::WitAPI->new(
        bus => $self->{bus}, store => $self->{store}, session => $self->{session},
        ui => $self->{ui}, wit_name => $name,
    );
    eval { $wit->register($api); 1 } or do {
        my $err = "$@";
        push @{ $self->{errors} }, "$dir: register failed: $err";
        warn "[wits] $name: register() failed: $err";
        return;
    };

    my $rec = { name => $name, pkg => $pkg, dir => $dir, wit => $wit, api => $api };
    push @{ $self->{wits} }, $rec;
    $self->{apis}{$name} = $api;
    return $rec;
}

# Bind runtime objects before loading (bus/store/session/ui).
sub bind { my ($self, %o) = @_; $self->{$_} = $o{$_} for qw(bus store session ui); return $self }

# Return refs (not lists): callers dereference, and list-returning accessors
# misbehave in scalar context (e.g. `@{ $pm->errors }`).
sub wits      { $_[0]->{wits} }
sub errors    { $_[0]->{errors} }
sub skipped   { $_[0]->{skipped} }          # declarative wits skipped for missing deps
sub dwits     { $_[0]->{dwits} }            # name/trigger -> declarative wit record
sub dispatch  { $_[0]->{dispatch} }         # Clam::WitDispatch (the $ctx{wits} object)
sub api_for   { $_[0]->{apis}{ $_[1] } }

# All wit-registered tools as Clam::Tool objects.
sub all_tools {
    my ($self) = @_;
    require Clam::Tool;
    return map { Clam::Tool->new(%$_) } map { @{ $_->{api}->registered_tools } } @{ $self->{wits} };
}

# Merged slash commands: name -> {description, handler, wit}.
sub all_commands {
    my ($self) = @_;
    my %cmds;
    for my $rec (@{ $self->{wits} }) {
        for my $name (keys %{ $rec->{api}->registered_commands }) {
            $cmds{$name} = { %{ $rec->{api}->registered_commands->{$name} }, wit => $rec->{name} };
        }
    }
    return \%cmds;
}

1;
