# Application object: owns store/bus/provider/compactor, starts sessions with
# wits loaded (tools + resources attached). Shared by REPL and one-shot mode.
package AI::Clam::App;
use strict;
use warnings;
use Cwd qw(getcwd);
use AI::Clam qw(builtin_tools version);
use AI::Clam::Store;
use AI::Clam::Bus;
use AI::Clam::Session;
use AI::Clam::Loop;
use AI::Clam::Providers;
use AI::Clam::PluginManager;
use AI::Clam::Skills;
use AI::Clam::Session::Compaction;
use AI::Clam::WorldModel;
use AI::Clam::Governor;
use AI::Clam::Tracer;
use AI::Clam::Cache;
use AI::Clam::Metrics;
use AI::Clam::Constraints;
use AI::Clam::Crystallizer;
use AI::Clam::NeuroIntegration;

sub new {
    my ($class, %o) = @_;
    my $app = bless {
        wit_paths => [],
        stream    => 0,
        %o,
    }, $class;
    $app->{store}    = AI::Clam::Store->new(path => $o{db} // "$ENV{HOME}/.clam/clam.db");
    $app->{bus}      = AI::Clam::Bus->new(store => $app->{store}, sender => 'app');
    # provider: a name (registry lookup) or a ready-made provider object — the
    # latter is how tests and drivers inject scripted/mock providers.
    $app->{provider} = ref($o{provider}) ? $o{provider} : AI::Clam::Providers->create(
        name     => $o{provider},
        model    => $o{model},
        base_url => $o{base_url},
        api_key  => $o{api_key},
    );
    $app->{compactor} = AI::Clam::Session::Compaction->new(%{ $o{compact} // {} });

    # Shared neurosymbolic primitives (survive across sessions).
    $app->{world_model} = AI::Clam::WorldModel->new(store => $app->{store});
    $app->{governor}    = AI::Clam::Governor->new(store => $app->{store}, bus => $app->{bus});
    $app->{tracer}      = AI::Clam::Tracer->new(store => $app->{store});
    $app->{cache}       = AI::Clam::Cache->new(store => $app->{store}, namespace => 'llm');
    $app->{metrics}     = AI::Clam::Metrics->new(store => $app->{store});

    return $app;
}

sub store     { $_[0]->{store} }
sub bus       { $_[0]->{bus} }
sub provider  { $_[0]->{provider} }
sub compactor { $_[0]->{compactor} }
sub session   { $_[0]->{session} }
sub loop      { $_[0]->{loop} }
sub pm        { $_[0]->{pm} }
sub wits      { @{ $_[0]->{wits} // [] } }

# Create (or resume) a session, load wits, attach tools + discovered resources.
sub start_session {
    my ($self, %o) = @_;
    my $session;
    if ($o{resume}) {
        die "no such session: $o{resume}\n" unless $self->{store}->get_session($o{resume});
        $session = AI::Clam::Session->new(
            store => $self->{store}, bus => $self->{bus},
            id => $o{resume}, provider => $self->{provider},
        );
    } else {
        $session = AI::Clam::Session->new(
            store => $self->{store}, bus => $self->{bus},
            provider => $self->{provider}, cwd => getcwd(),
        );
    }

    # wits: load + register (error-isolated per wit)
    my $pm = AI::Clam::PluginManager->new;
    $pm->bind(bus => $self->{bus}, store => $self->{store}, session => $session);

    # built-in wits ship with the harness (session management, etc.)
    $pm->load_builtins('AI::Clam::Wit::Session');

    # discovered wits from filesystem roots
    my @wits = $pm->load_all(extra_paths => $self->{wit_paths});

    # tools: builtins + wit-registered
    $session->add_tool($_) for builtin_tools();
    $session->add_tool($_) for $pm->all_tools();

    # resources_discover (collect-all): on-disk skills + wit-provided
    my (@skills, %seen);
    push @skills, grep { !$seen{ $_->{name} }++ } AI::Clam::Skills::discover();
    my $rd = $self->{bus}->publish('resources_discover', {});
    for my $r (@{ $rd->{results} }) {
        next unless ref $r eq 'HASH';
        push @skills, grep { !$seen{ $_->{name} }++ } @{ $r->{skills} // [] };
    }
    my @ctx = map { @{ $_->{context_files} // [] } }
              grep { ref $_ eq 'HASH' } @{ $rd->{results} };
    $session->set_skills(\@skills);
    $session->set_context_files(\@ctx);

    # Bus-driven neurosymbolic wits (subscribe to events automatically).
    my $api = _make_api($self);

    AI::Clam::NeuroIntegration->new(
        world_model => $self->{world_model},
        provider    => $self->{provider},
        tracer      => $self->{tracer},
        metrics     => $self->{metrics},
    )->register($api);

    AI::Clam::Crystallizer->new(
        world_model => $self->{world_model},
        provider    => $self->{provider},
        tracer      => $self->{tracer},
        metrics     => $self->{metrics},
    )->register($api);

    AI::Clam::Constraints->new(
        world_model => $self->{world_model},
        tracer      => $self->{tracer},
        metrics     => $self->{metrics},
    )->register($api);

    $self->{pm}      = $pm;
    $self->{wits}    = \@wits;
    $self->{session} = $session;
    $self->{loop}    = AI::Clam::Loop->new(
        session  => $session,
        stream   => $self->{stream},
        compactor => $self->{compactor},
        governor => $self->{governor},
        tracer   => $self->{tracer},
        cache    => $self->{cache},
        metrics  => $self->{metrics},
    );

    # Register subagent spawn tool (needs loop reference).
    require AI::Clam::Tools::Spawn;
    $session->add_tool(AI::Clam::Tools::Spawn->new(loop => $self->{loop}));

    $self->{bus}->publish('session_start', { session_id => $session->id });
    return $session;
}

sub run_prompt { $_[0]->{loop}->run_prompt($_[1]) }

sub shutdown {
    my ($self) = @_;
    $self->{bus}->publish('session_shutdown', {}) if $self->{bus};
}

# Create a minimal Wit::API-like object for bus-driven wits.
sub _make_api {
    my ($app) = @_;
    require AI::Clam::Wit::API;
    return AI::Clam::Wit::API->new(
        bus   => $app->{bus},
        store => $app->{store},
    );
}

1;
