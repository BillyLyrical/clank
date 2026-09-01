# Clam::WitLoader — loads declarative .wit files (clam-old format) into a
# WitAPI as LLM-callable tools, with inter-wit dispatch, bus subscriptions,
# state persistence, and timeouts.  See docs/DESIGN.md section 9 and
# decks/README.md for the deck model.
package Clam::WitLoader;
use strict;
use warnings;
use File::Find;
use Clam::WitFile;
use Clam::Util qw(jencode);

# Recursion depth of bus-agent dispatch (see the subscribe closure in
# _load_one).  Guards against result topics that match their own subscription
# pattern, e.g. search.* vs search.results.  Capped like the old Bus (5).
our $BUS_AGENT_DEPTH = 0;

# Derived names of all .wit files under $dir (path relative to $dir, minus
# extension) — same rule as load_dir uses for registration.  Used by the CLI
# to validate deck manifests without loading anything.
sub list_wits {
    my ($class, $dir) = @_;
    return [] unless -d $dir;
    my @names;
    find({ wanted => sub {
        return unless /\.wit$/ && -f $_;
        (my $n = $File::Find::name) =~ s{^\Q$dir\E/?}{};
        $n =~ s{\.wit$}{};
        $n =~ s{/}{.}g;   # same derived-name rule as load_dir
        push @names, $n;
    }, no_chdir => 1 }, $dir);
    return [ sort @names ];
}

# Load every .wit file under $dir (recursively) into $api.
# Returns an arrayref of declarative wit records.  Per-file failures are
# recorded on the PluginManager and never abort the batch.
sub load_dir {
    my ($class, $pm, $api, $dir) = @_;
    my @files;
    find({ wanted => sub { push @files, $File::Find::name if /\.wit$/ && -f $_ }, no_chdir => 1 }, $dir);

    my @records;
    for my $file (sort @files) {
        # Name derived from the path relative to the deck root — same rule as
        # the clam-old Loader: deduction/axiom.wit -> "deduction.axiom" (path
        # separators become dots), a top-level foo.wit -> "foo".  Cross-wit
        # references rely on this.
        (my $rel = $file) =~ s{^\Q$dir\E/?}{};
        (my $name = $rel) =~ s{\.wit$}{};
        $name =~ s{/}{.}g;

        my $rec = eval { _load_one($pm, $api, $dir, $file, $name) };
        if ($@) {
            push @{ $pm->{errors} }, "$file: $@";
            warn "[wits] failed to load $file: $@";
            next;
        }
        push @records, $rec if $rec;
    }
    return \@records;
}

sub _load_one {
    my ($pm, $api, $dir, $file, $name) = @_;
    my $parsed = Clam::WitFile->parse_file($file);   # dies on malformed files
    my ($meta, $source) = ($parsed->{meta}, $parsed->{source});

    return undef unless _truthy($meta->{enabled} // 1);

    # Requirements gate: skip (with a note, not an error) when the host lacks
    # a declared Perl module or binary.
    for my $mod (@{ $meta->{requires_perl} // [] }) {
        eval { _require_module($mod); 1 } or do {
            push @{ $pm->{skipped} }, "$name: missing Perl module $mod";
            return undef;
        };
    }
    for my $bin (@{ $meta->{requires_bin} // [] }) {
        unless (_have_bin($bin)) {
            push @{ $pm->{skipped} }, "$name: missing binary $bin";
            return undef;
        }
    }

    my $code = Clam::WitFile->compile($source, name => $name);   # dies on error

    my $rec;   # declared before the initializer: the run closures reference it
    $rec = {
        name  => $name,
        file  => $file,
        dir   => $dir,
        meta  => $meta,
        code  => $code,
        wit   => bless({ %$meta }, 'Clam::WitFile::Record'),
        # top-level run: with the declared timeout (tool entry point)
        run          => sub { _execute($pm, $rec, $_[0], timeout => ($meta->{timeout} // 30)) },
        # inter-wit run: no nested alarm (alarms are process-global; nesting
        # would cancel the outer timer), depth is guarded by the dispatcher.
        run_notimeout => sub { _execute($pm, $rec, $_[0], timeout => 0) },
    };

    # Register as an LLM-callable tool.  Old wits document their inputs in the
    # usage text rather than a JSON schema, so parameters stay generic and the
    # description carries the contract.
    my $desc = $meta->{description} // '';
    $desc .= "\n" . $meta->{usage} if length($meta->{usage} // '');
    $api->register_tool(
        name        => $name,
        description => $desc,
        parameters  => { type => 'object' },
        execute     => sub {
            my ($args) = @_;
            my $input = ref $args eq 'HASH' ? $args : (defined $args ? { text => "$args" } : {});
            my ($result, $error) = $rec->{run}->($input);
            return { output => "wit '$name' failed: $error", isError => 1 } if $error;
            return { output => defined $result ? jencode($result) : 'null', isError => 0 };
        },
    );

    # Dispatch aliases: the derived name, the TOML name field, and triggers.
    $pm->{dwits}{$name} = $rec;
    $pm->{dwits}{$_} = $rec for grep { defined && length } @{ $meta->{triggers} // [] };
    $pm->{dwits}{ $meta->{name} } = $rec if defined $meta->{name} && length $meta->{name};

    # Bus agent: a wit with subscribes=[...] reacts to published events and
    # publishes its result (DESIGN section 8 bus-agent pattern).
    my $bus = $pm->{bus};
    if ($bus) {
        for my $topic (@{ $meta->{subscribes} // [] }) {
            $bus->subscribe($topic, sub {
                my ($ev) = @_;
                # Recursion cap: a result topic can match the subscription
                # pattern (e.g. search.* vs search.results).  The old Bus
                # republished recursively with max depth 5; mirror that.
                return if $Clam::WitLoader::BUS_AGENT_DEPTH >= 5;
                local $Clam::WitLoader::BUS_AGENT_DEPTH = $Clam::WitLoader::BUS_AGENT_DEPTH + 1;
                my $payload = $ev->{payload};
                my $input = ref $payload eq 'HASH' ? $payload
                            : (defined $payload ? { text => "$payload" } : {});
                my ($result) = $rec->{run_notimeout}->($input);
                return unless defined $result;
                my @pub = @{ $meta->{publishes} // [] };
                $bus->publish(@pub ? $pub[0] : "${topic}.result", { %$result, _wit => $name });
            }, name => "wit.$name.$topic");
        }
    }
    return $rec;
}

# Execute a declarative wit with the full context.  Returns ($result, $error).
sub _execute {
    my ($pm, $rec, $input, %o) = @_;
    my $meta = $rec->{meta};

    my %ctx = (
        wits      => $pm->{dispatch},
        bus       => $pm->{bus} ? Clam::WitLoader::BusAdapter->new($pm->{bus}) : undef,
        store     => $pm->{store},
        session   => $pm->{session},
        config    => {},
        clam_home => _clam_home(),
        workdir   => sub { my ($tag) = @_; return _make_workdir($tag // 'wit') },
    );
    if (_truthy($meta->{stateful})) {
        $ctx{state} = _load_state($pm, $rec->{name}) // {};
    }

    my ($result, $error) = _with_timeout($o{timeout}, sub {
        return $rec->{code}->($rec->{wit}, $input, %ctx);
    });

    if (_truthy($meta->{stateful}) && !$error) {
        _save_state($pm, $rec->{name}, $ctx{state});
    }
    return ($result, $error);
}

# alarm() + blocking eval.  The handler is `local` at THIS subroutine's scope
# (an inner-block local would restore the default handler early and let a
# pending SIGALRM kill the process — see Clam::Tools::Bash for the history).
sub _with_timeout {
    my ($secs, $code) = @_;
    return ($code->(), undef) unless defined $secs && $secs > 0;
    my ($result, $error);
    local $SIG{ALRM} = sub { die "timed out after ${secs}s\n" };
    eval { alarm($secs); $result = $code->(); alarm(0); 1 } or do { $error = "$@" };
    return ($result, $error);
}

# ---------------------------------------------------------------------------
sub _truthy { defined $_[0] && $_[0] ? 1 : 0 }

sub _clam_home {
    my $home = $ENV{CLAM_HOME} // (defined $ENV{HOME} ? "$ENV{HOME}/.clam" : '.');
    return $home;
}

sub _make_workdir {
    my ($tag) = @_;
    require File::Path;
    my $base = _clam_home() . '/work';
    File::Path::make_path($base) unless -d $base;
    my $dir = sprintf('%s/%s-%d-%04x', $base, $tag, time(), int(rand(0xffff)));
    File::Path::make_path($dir);
    return $dir;
}

sub _load_state {
    my ($pm, $name) = @_;
    return undef unless $pm->{store};
    my $v = eval { $pm->{store}->kv_get("wit_state.$name") };
    warn "[wits] state load failed for '$name': $@" if $@;
    return ref $v eq 'HASH' ? $v : undef;
}

sub _save_state {
    my ($pm, $name, $state) = @_;
    return unless $pm->{store} && ref $state eq 'HASH';
    eval { $pm->{store}->kv_set("wit_state.$name", $state); 1 }
        or warn "[wits] state save failed for '$name': $@";
}

# ---------------------------------------------------------------------------
# Clam::WitLoader::BusAdapter — the object wits receive as $ctx{bus}.
# publish() keeps all real-bus side effects (journaling, dispatch) but also
# returns the first hashref handler result, restoring the reply semantics the
# old-tree search wits were written against (the old Bus was fire-and-forget,
# which left them dead code).  Other methods pass through.
# ---------------------------------------------------------------------------
package Clam::WitLoader::BusAdapter;

sub new { my ($class, $bus) = @_; return bless { bus => $bus }, $class }

sub publish {
    my ($self, $topic, $payload) = @_;
    my $r = eval { $self->{bus}->publish($topic, $payload) };
    return undef if $@;
    for my $h (@{ ref $r eq 'HASH' ? ($r->{results} // []) : () }) {
        return $h if ref $h eq 'HASH';
    }
    return undef;
}

sub subscribe   { my ($self, @a) = @_; $self->{bus}->subscribe(@a) }
sub unsubscribe { my ($self, $id) = @_; $self->{bus}->unsubscribe($id) }

package Clam::WitLoader;

sub _require_module {
    my ($mod) = @_;
    (my $file = $mod) =~ s{::}{/}g;
    require "$file.pm";
}

sub _have_bin {
    my ($bin) = @_;
    return 1 if -x $bin && $bin =~ m{[/\\]};   # absolute path
    for my $dir (split /:/, ($ENV{PATH} // '')) {
        next unless length $dir;
        return 1 if -x "$dir/$bin";
    }
    return 0;
}

1;
