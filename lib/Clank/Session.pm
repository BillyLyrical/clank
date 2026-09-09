# A conversation session: message tree + system prompt + tools, bound to store/bus/provider.
package Clank::Session;
use strict;
use warnings;
use Cwd qw(getcwd);
use Clank::Session::Messages ();
use Clank::Session::SystemPrompt ();

my %SNIPPETS = (
    read  => 'Read file contents',
    bash  => 'Execute bash commands',
    edit  => 'Make precise file edits with exact text replacement',
    write => 'Create or overwrite files',
);

sub new {
    my ($class, %o) = @_;
    my $store = $o{store} or die "Clank::Session requires store";
    my $id = $o{id} // $store->create_session(
        title => $o{name}, cwd => $o{cwd} // getcwd(), model => ($o{provider} && $o{provider}{model}) );
    return bless {
        store         => $store,
        bus           => $o{bus},
        id            => $id,
        name          => $o{name},
        cwd           => $o{cwd} // getcwd(),
        provider      => $o{provider},
        tools         => [],
        system_prompt => $o{system_prompt},   # optional override; built lazily
        skills        => $o{skills}        // [],
        context_files => $o{context_files} // [],
    }, $class;
}

sub id       { $_[0]->{id} }
sub store    { $_[0]->{store} }
sub bus      { $_[0]->{bus} }
sub provider { $_[0]->{provider} }
sub cwd      { $_[0]->{cwd} }

sub add_tool { my ($s, $t) = @_; push @{ $s->{tools} }, $t; return $s }
sub tools    {
    my ($self) = @_;
    my @all = @{ $self->{tools} };
    return @all unless $self->{tool_filter};
    my %allowed = map { $_ => 1 } @{ $self->{tool_filter} };
    return grep { $allowed{ $_->{name} } } @all;
}
sub tool_names { map { $_->{name} } $_[0]->tools }

# Restrict which tools are available in this session.
# Pass an arrayref of tool names, or undef to clear the filter.
sub set_tool_filter {
    my ($self, $names) = @_;
    $self->{tool_filter} = $names;
}

sub system_prompt {
    my ($self) = @_;
    return $self->{system_prompt} if defined $self->{system_prompt};
    $self->{system_prompt} = Clank::Session::SystemPrompt::build(
        cwd            => $self->{cwd},
        selected_tools => [ $self->tool_names ],
        tool_snippets  => \%SNIPPETS,
        skills         => $self->{skills},
        context_files  => $self->{context_files},
        manifest       => $self->{manifest},
    );
    return $self->{system_prompt};
}

sub set_system_prompt { $_[0]->{system_prompt} = $_[1] }
sub set_skills        { $_[0]->{skills} = $_[1] }
sub set_context_files { $_[0]->{context_files} = $_[1] }
sub set_manifest {
    my ($self, $manifest) = @_;
    $self->{manifest} = $manifest;
    # Invalidate cached system prompt so it rebuilds with the new manifest.
    delete $self->{system_prompt};
}

# Provider messages for the current head (pre-hook).
sub build_context {
    my ($self) = @_;
    my $chain = Clank::Session::Messages::chain($self->{store}, $self->{id});
    return Clank::Session::Messages::to_provider_list($chain);
}

sub add_user_message      { my ($s, $t)  = @_; Clank::Session::Messages::add($s->{store}, $s->{id}, role => 'user', content => $t) }
sub add_assistant_message { my ($s, %a)  = @_; Clank::Session::Messages::add($s->{store}, $s->{id}, role => 'assistant', content => \%a) }
sub add_tool_result       {
    my ($s, $tc_id, $out, $is_err) = @_;
    Clank::Session::Messages::add($s->{store}, $s->{id}, role => 'toolResult',
        content => { tool_call_id => $tc_id, output => $out, isError => $is_err ? 1 : 0 });
}

sub est_context_tokens {
    my ($self) = @_;
    return Clank::Session::Messages::est_tokens([
        { role => 'system', content => $self->system_prompt },
        @{ $self->build_context },
    ]);
}

1;
