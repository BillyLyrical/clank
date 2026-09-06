# Application object: owns store/bus/provider/compactor, starts sessions with
# wits loaded (tools + resources attached). Shared by REPL and one-shot mode.
package Clam::App;
use strict;
use warnings;
use Cwd qw(getcwd);
use Clam qw(builtin_tools version);
use Clam::Store;
use Clam::Bus;
use Clam::Session;
use Clam::Loop;
use Clam::Providers;
use Clam::PluginManager;
use Clam::Skills;
use Clam::Compaction;

sub new {
    my ($class, %o) = @_;
    my $app = bless {
        wit_paths => [],
        stream    => 0,
        %o,
    }, $class;
    $app->{store}    = Clam::Store->new(path => $o{db} // "$ENV{HOME}/.clam/clam.db");
    $app->{bus}      = Clam::Bus->new(store => $app->{store}, sender => 'app');
    # provider: a name (registry lookup) or a ready-made provider object — the
    # latter is how tests and drivers inject scripted/mock providers.
    $app->{provider} = ref($o{provider}) ? $o{provider} : Clam::Providers->create(
        name     => $o{provider},
        model    => $o{model},
        base_url => $o{base_url},
        api_key  => $o{api_key},
    );
    $app->{compactor} = Clam::Compaction->new(%{ $o{compact} // {} });
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
        $session = Clam::Session->new(
            store => $self->{store}, bus => $self->{bus},
            id => $o{resume}, provider => $self->{provider},
        );
    } else {
        $session = Clam::Session->new(
            store => $self->{store}, bus => $self->{bus},
            provider => $self->{provider}, cwd => getcwd(),
        );
    }

    # wits: load + register (error-isolated per wit)
    my $pm = Clam::PluginManager->new;
    $pm->bind(bus => $self->{bus}, store => $self->{store}, session => $session);

    # built-in wits ship with the harness (session management, etc.)
    $pm->load_builtins('Clam::Wit::Session');

    # discovered wits from filesystem roots
    my @wits = $pm->load_all(extra_paths => $self->{wit_paths});

    # tools: builtins + wit-registered
    $session->add_tool($_) for builtin_tools();
    $session->add_tool($_) for $pm->all_tools();

    # resources_discover (collect-all): on-disk skills + wit-provided
    my (@skills, %seen);
    push @skills, grep { !$seen{ $_->{name} }++ } Clam::Skills::discover();
    my $rd = $self->{bus}->publish('resources_discover', {});
    for my $r (@{ $rd->{results} }) {
        next unless ref $r eq 'HASH';
        push @skills, grep { !$seen{ $_->{name} }++ } @{ $r->{skills} // [] };
    }
    my @ctx = map { @{ $_->{context_files} // [] } }
              grep { ref $_ eq 'HASH' } @{ $rd->{results} };
    $session->set_skills(\@skills);
    $session->set_context_files(\@ctx);

    $self->{pm}      = $pm;
    $self->{wits}    = \@wits;
    $self->{session} = $session;
    $self->{loop}    = Clam::Loop->new(
        session => $session, stream => $self->{stream}, compactor => $self->{compactor});

    $self->{bus}->publish('session_start', { session_id => $session->id });
    return $session;
}

sub run_prompt { $_[0]->{loop}->run_prompt($_[1]) }

sub shutdown {
    my ($self) = @_;
    $self->{bus}->publish('session_shutdown', {}) if $self->{bus};
}

1;
