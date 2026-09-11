# Application object: owns store/bus/provider/compactor, starts sessions with
# wits loaded (tools + resources attached). Shared by REPL and one-shot mode.
package Clank::App;
use strict;
use warnings;
use Cwd qw(getcwd);
use Clank qw(builtin_tools version);
use Clank::Store;
use Clank::Bus;
use Clank::Session;
use Clank::Loop;
use Clank::Providers;
use Clank::PluginManager;
use Clank::Skills;
use Clank::Session::Compaction;
use Clank::WorldModel;
use Clank::Governor;
use Clank::Tracer;
use Clank::Cache;
use Clank::Metrics;
use Clank::Constraints;
use Clank::Crystallizer;
use Clank::NeuroIntegration;

sub new {
    my ($class, %o) = @_;
    my $app = bless {
        wit_paths => [],
        stream    => 0,
        %o,
    }, $class;
    $app->{store}    = Clank::Store->new(path => $o{db} // "$ENV{HOME}/.clank/clank.db");
    $app->{bus}      = Clank::Bus->new(store => $app->{store}, sender => 'app');

    # provider: a name (registry lookup) or a ready-made provider object — the
    # latter is how tests and drivers inject scripted/mock providers.
    $app->{provider} = ref($o{provider}) ? $o{provider} : Clank::Providers->create(
        name     => $o{provider},
        model    => $o{model},
        base_url => $o{base_url},
        api_key  => $o{api_key},
    );
    $app->{compactor} = Clank::Session::Compaction->new(%{ $o{compact} // {} });

    # Shared neurosymbolic primitives (survive across sessions).
    $app->{world_model} = Clank::WorldModel->new(store => $app->{store});
    $app->{governor}    = Clank::Governor->new(store => $app->{store}, bus => $app->{bus});
    $app->{tracer}      = Clank::Tracer->new(store => $app->{store});
    $app->{cache}       = Clank::Cache->new(store => $app->{store}, namespace => 'llm');
    $app->{metrics}     = Clank::Metrics->new(store => $app->{store});

    return $app;
}

sub store     { $_[0]->{store} }
sub bus       { $_[0]->{bus} }
sub provider  { $_[0]->{provider} }
sub compactor { $_[0]->{compactor} }
sub session   { $_[0]->{session} }
sub loop      { $_[0]->{loop} }
sub pm        { $_[0]->{pm} }
sub metrics   { $_[0]->{metrics} }
sub wits      { @{ $_[0]->{wits} // [] } }

# Create (or resume) a session, load wits, attach tools + discovered resources.
sub start_session {
    my ($self, %o) = @_;
    my $session;
    if ($o{resume}) {
        die "no such session: $o{resume}\n" unless $self->{store}->get_session($o{resume});
        $session = Clank::Session->new(
            store => $self->{store}, bus => $self->{bus},
            id => $o{resume}, provider => $self->{provider},
        );
    } else {
        $session = Clank::Session->new(
            store => $self->{store}, bus => $self->{bus},
            provider => $self->{provider}, cwd => getcwd(),
        );
    }

    # wits: load + register (error-isolated per wit)
    my $pm = Clank::PluginManager->new;
    $pm->bind(bus => $self->{bus}, store => $self->{store}, session => $session);

    # built-in wits ship with the harness (session management, etc.)
    $pm->load_builtins('Clank::Wit::Session');

    # discovered wits from filesystem roots
    my @wits = $pm->load_all(extra_paths => $self->{wit_paths});

    # Scan filesystem for # CLANK-WIT: markers and register in DB.
    # This populates the wit registry so ~ list shows all available wits.
    require Clank::Wit::Scanner;
    my $scanned = Clank::Wit::Scanner->scan(dirs => [
        map { "$_/Clank/Wits" } grep { -d "$_/Clank/Wits" } @INC
    ]);
    Clank::Wit::Scanner->register_in_db($self->{store}, $scanned) if @$scanned;

    # Mark loaded wits as active in the DB.
    for my $w (@wits) {
        $self->{store}->wit_set_state($w->{name}, 'active');
    }

    # tools: builtins + wit-registered
    $session->add_tool($_) for builtin_tools();
    $session->add_tool($_) for $pm->all_tools();

    # resources_discover (collect-all): on-disk skills + wit-provided
    my (@skills, %seen);
    push @skills, grep { !$seen{ $_->{name} }++ } Clank::Skills::discover();
    my $rd = $self->{bus}->publish('resources_discover', {});
    for my $r (@{ $rd->{results} }) {
        next unless ref $r eq 'HASH';
        push @skills, grep { !$seen{ $_->{name} }++ } @{ $r->{skills} // [] };
    }
    my @ctx = map { @{ $_->{context_files} // [] } }
              grep { ref $_ eq 'HASH' } @{ $rd->{results} };
    $session->set_skills(\@skills);
    $session->set_context_files(\@ctx);

    # Capability manifest: deck-level overview for the system prompt.
    # Generated after wits are loaded so it reflects actual state.
    $session->set_manifest($pm->manifest);

    # Bus-driven neurosymbolic wits (subscribe to events automatically).
    my $api = _make_api($self);

    # Register world model for knowledge requests.
    $self->{world_model}->register($api);

    Clank::NeuroIntegration->new(
        world_model => $self->{world_model},
        provider    => $self->{provider},
        tracer      => $self->{tracer},
        metrics     => $self->{metrics},
    )->register($api);

    Clank::Crystallizer->new(
        world_model => $self->{world_model},
        provider    => $self->{provider},
        tracer      => $self->{tracer},
        metrics     => $self->{metrics},
    )->register($api);

    Clank::Constraints->new(
        world_model => $self->{world_model},
        tracer      => $self->{tracer},
        metrics     => $self->{metrics},
    )->register($api);

    # Escalation: cheapest correct tool first (before LLM call).
    require Clank::Escalation;
    Clank::Escalation->new(
        store       => $self->{store},
        bus         => $self->{bus},
        provider    => $self->{provider},
        world_model => $self->{world_model},
        tracer      => $self->{tracer},
        metrics     => $self->{metrics},
    )->register($api);

    # Metrics bus handler: respond to metrics.self_stats queries.
    if ($self->{metrics}) {
        my $metrics = $self->{metrics};
        $api->on('metrics.self_stats', sub { return $metrics->self_stats });
    }

    # Perl Execution Environment: neurosymbolic loop for Perl code.
    require Clank::PerlEnv;
    my $perl_env = Clank::PerlEnv->new(
        store        => $self->{store},
        bus          => $self->{bus},
        world_model  => $self->{world_model},
        metrics      => $self->{metrics},
        tracer       => $self->{tracer},
    );
    $perl_env->register($api);

    # PerlLoop: agent loop connecting LLM to PerlEnv.
    require Clank::PerlLoop;
    Clank::PerlLoop->new(
        store    => $self->{store},
        bus      => $self->{bus},
        provider => $self->{provider},
        session  => $session,
        perl_env => $perl_env,
        metrics  => $self->{metrics},
        tracer   => $self->{tracer},
    )->register($api);

    $self->{pm}      = $pm;
    $self->{wits}    = \@wits;
    $self->{session} = $session;
    $self->{loop}    = Clank::Loop->new(
        session  => $session,
        stream   => $self->{stream},
        compactor => $self->{compactor},
        governor => $self->{governor},
        tracer   => $self->{tracer},
        cache    => $self->{cache},
        metrics  => $self->{metrics},
    );

    # Register subagent spawn tool (needs loop reference).
    require Clank::Tools::Spawn;
    $session->add_tool(Clank::Tools::Spawn->new(loop => $self->{loop}));

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
    require Clank::Wit::API;
    return Clank::Wit::API->new(
        bus   => $app->{bus},
        store => $app->{store},
    );
}

1;
