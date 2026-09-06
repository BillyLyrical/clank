# The agent loop. Every Pi extension event is a bus topic; wits subscribe and
# influence the run via per-topic reducer rules (see docs/ROADMAP.md §5).
#
# Optional integrations (all bus-driven, no hard deps):
#   governor — rate limiting, budget cap, circuit breaker (wraps provider calls)
#   tracer   — auto-trace pipeline stages (agent, turn, provider_call)
#   cache    — LLM response caching (non-streaming only)
#   metrics  — counters for turns, tool calls, errors
package Clam::Loop;
use strict;
use warnings;
use Clam::Util qw(jencode jdecode);

sub new {
    my ($class, %o) = @_;
    my $session = $o{session} or die "Clam::Loop requires session\n";
    return bless {
        session   => $session,
        stream    => $o{stream} // 0,
        max_turns => $o{max_turns} // 50,
        compactor => $o{compactor},

        # Optional neurosymbolic primitives.
        governor  => $o{governor},
        tracer    => $o{tracer},
        cache     => $o{cache},
        metrics   => $o{metrics},
        max_tools => $o{max_tools},    # RATS: max tools to send to LLM (undef = all)

        aborted   => 0,
    }, $class;
}

sub abort { $_[0]->{aborted} = 1 }

sub _bus      { $_[0]->{session}{bus} or die "session has no bus" }
sub _provider { $_[0]->{session}{provider} or die "session has no provider" }

# ---------------------------------------------------------------------------
# run_prompt: full per-prompt lifecycle. Returns a result hashref.
# ---------------------------------------------------------------------------
sub run_prompt {
    my ($self, $text) = @_;
    my $bus     = $self->_bus;
    my $session = $self->{session};

    # --- Tracer: wrap entire prompt in agent span ---
    my $agent_span;
    $agent_span = $self->{tracer}->start_span('agent.run_prompt', topic => 'agent')
        if $self->{tracer};
    $self->{metrics}->inc('agent.runs') if $self->{metrics};

    # 1) input hook: continue | transform | handled
    my $pub = $bus->publish('input', { text => $text, source => 'interactive' });
    my ($final_text, $handled_out) = ($text);
    for my $r (@{ $pub->{results} }) {
        next unless ref $r eq 'HASH';
        if (($r->{action} // '') eq 'transform' && defined $r->{text}) { $final_text = $r->{text} }
        elsif (($r->{action} // '') eq 'handled') { $handled_out = $r->{output}; last }
    }
    if (defined $handled_out) {
        $self->{tracer}->end_span($agent_span) if $self->{tracer} && $agent_span;
        return { ok => 1, handled => 1, output => $handled_out };
    }

    # 2) record user message; before_agent_start (inject message / chain systemPrompt)
    $session->add_user_message($final_text);
    my $sp = $session->system_prompt;
    my @inject;
    my $ba = $bus->publish('before_agent_start', { prompt => $final_text, systemPrompt => $sp });
    for my $r (@{ $ba->{results} }) {
        next unless ref $r eq 'HASH';
        push @inject, $r->{message} if defined $r->{message};
        $sp = $r->{systemPrompt} if defined $r->{systemPrompt};
    }
    $session->set_system_prompt($sp);
    $session->add_user_message("[$_]") for @inject;

    $bus->publish('agent_start', { prompt => $final_text, session_id => $session->id });

    my ($turn, $last_error) = (0);
    while (!$self->{aborted}) {
        last if ++$turn > $self->{max_turns};

        # --- Tracer: wrap turn in span ---
        my $turn_span;
        $turn_span = $self->{tracer}->start_span("turn.$turn", topic => 'turn')
            if $self->{tracer};
        $self->{metrics}->inc('agent.turns') if $self->{metrics};

        $bus->publish('turn_start', { turn => $turn, session_id => $session->id });

        # 3) context hook: replace messages (chained across wits)
        my $msgs = $session->build_context;
        my $cx   = $bus->publish('context', { messages => $msgs, system_prompt => $sp });
        for my $r (@{ $cx->{results} }) {
            $msgs = $r->{messages} if ref $r eq 'HASH' && ref $r->{messages} eq 'ARRAY';
        }

        # 4) build provider payload; before_provider_request may replace it.
        # RATS: select relevant tools based on the current prompt.
        my @all_tools = $session->tools;
        my @schemas;
        if ($self->{max_tools} && @all_tools > $self->{max_tools}) {
            require Clam::ToolSelector;
            my $last_msg = $msgs->[-1]{content} // '';
            my $selected = Clam::ToolSelector->select(
                tools  => \@all_tools,
                prompt => $last_msg,
                max    => $self->{max_tools},
            );
            @schemas = map { $_->openai_schema } @$selected;
            $self->{metrics}->inc('tools.rats_filtered') if $self->{metrics};
        } else {
            @schemas = map { $_->openai_schema } @all_tools;
        }
        my $payload = $self->_provider->chat_payload(
            messages => [ { role => 'system', content => $sp }, @$msgs ],
            tools    => \@schemas,
        );
        delete $payload->{stream};
        my $bpr = $bus->publish('before_provider_request', { payload => $payload });
        for my $r (@{ $bpr->{results} }) {
            $payload = $r->{payload} if ref $r eq 'HASH' && ref $r->{payload} eq 'HASH';
        }

        # --- Governor: check before provider call ---
        if ($self->{governor}) {
            my $model = $self->_provider->{model} // '';
            my ($ok, $reason) = $self->{governor}->check(
                model => $model, estimated_tokens => 2000);
            unless ($ok) {
                $self->{metrics}->inc('agent.throttled') if $self->{metrics};
                $self->{tracer}->end_span($turn_span) if $self->{tracer} && $turn_span;
                $bus->publish('turn_end', { turn => $turn, throttled => 1 });
                $last_error = "throttled: $reason";
                last;
            }
        }

        # --- Cache: check before provider call (non-streaming) ---
        my $cache_hit;
        if ($self->{cache} && !$self->{stream}) {
            my $cache_key = ref($self->{cache}) =~ /Cache/ ? $self->{cache}->make_key(
                model    => $self->_provider->{model} // '',
                messages => $payload->{messages},
                tools    => $payload->{tools},
            ) : undef;
            if ($cache_key) {
                $cache_hit = $self->{cache}->get($cache_key);
                $self->{metrics}->inc('cache.hits') if $self->{metrics} && $cache_hit;
                $self->{metrics}->inc('cache.misses') if $self->{metrics} && !$cache_hit;
            }
        }

        # 5) provider call (streaming optional; deltas -> message_update events)
        my ($resp, $err);
        if ($cache_hit) {
            $resp = $cache_hit;
        } else {
            # --- Tracer: wrap provider call ---
            my $prov_span;
            $prov_span = $self->{tracer}->start_span('provider.call', topic => 'provider')
                if $self->{tracer};

            eval { $resp = $self->_provider_call($payload) };

            if ($self->{tracer} && $prov_span) {
                my $usage = $resp->{usage} // {};
                $self->{tracer}->end_span($prov_span, {
                    input_tokens  => $usage->{prompt_tokens} // 0,
                    output_tokens => $usage->{completion_tokens} // 0,
                });
            }

            if ($@) {
                $last_error = "$@";
                $self->{metrics}->inc('agent.errors') if $self->{metrics};
                $self->{governor}->record_failure(
                    model => $self->_provider->{model} // '', fatal => 1)
                    if $self->{governor};
                $self->{tracer}->end_span($turn_span) if $self->{tracer} && $turn_span;
                $self->{tracer}->end_span($agent_span) if $self->{tracer} && $agent_span;
                $bus->publish('agent_end', { error => $last_error });
                return { ok => 0, error => $last_error, turns => $turn };
            }

            # --- Governor: record successful call ---
            if ($self->{governor} && $resp->{usage}) {
                my $u = $resp->{usage};
                $self->{governor}->record(
                    model         => $self->_provider->{model} // '',
                    input_tokens  => $u->{prompt_tokens} // 0,
                    output_tokens => $u->{completion_tokens} // 0,
                );
            }

            # --- Metrics: record tokens ---
            if ($self->{metrics} && $resp->{usage}) {
                $self->{metrics}->inc('llm.calls');
                $self->{metrics}->inc('llm.tokens.input', $resp->{usage}{prompt_tokens} // 0);
                $self->{metrics}->inc('llm.tokens.output', $resp->{usage}{completion_tokens} // 0);
            }

            # --- Cache: store response ---
            if ($self->{cache} && !$self->{stream}) {
                my $cache_key = ref($self->{cache}) =~ /Cache/ ? $self->{cache}->make_key(
                    model    => $self->_provider->{model} // '',
                    messages => $payload->{messages},
                    tools    => $payload->{tools},
                ) : undef;
                if ($cache_key) {
                    $self->{cache}->set($cache_key, $resp,
                        model => $self->_provider->{model} // '');
                    $self->{metrics}->inc('cache.sets') if $self->{metrics};
                }
            }
        }

        my $choice = $resp->{choices}[0] // {};
        my $msg    = $choice->{message} // {};
        my @tcs;
        for my $tc (@{ $msg->{tool_calls} // [] }) {
            my $args = eval { jdecode($tc->{function}{arguments}) } // {};
            push @tcs, { id => $tc->{id}, name => $tc->{function}{name}, arguments => $args };
        }

        # 6) after_provider_response (informational)
        $bus->publish('after_provider_response',
            { status => 200, usage => $resp->{usage}, stop_reason => $choice->{finish_reason} });

        my %assistant = ( text => ($msg->{content} // ''), tool_calls => \@tcs );

        # 7) message_end hook: may replace finalized assistant message (role must match)
        my $final = \%assistant;
        my $me = $bus->publish('message_end', { role => 'assistant', content => $final });
        for my $r (@{ $me->{results} }) {
            next unless ref $r eq 'HASH' && defined $r->{content};
            die "message_end handlers must return a message with the same role\n"
                if ($r->{role} // 'assistant') ne 'assistant';
            $final = $r->{content};
        }

        $session->add_assistant_message(%$final, stop_reason => $choice->{finish_reason});

        last unless @{ $final->{tool_calls} // [] };   # no tool calls -> agent done

        # 8) execute each tool call with hooks
        for my $tc (@{ $final->{tool_calls} }) {
            last if $self->{aborted};

            $self->{metrics}->inc('tools.calls') if $self->{metrics};

            # tool_call hook: input mutable in place; first block wins
            my $input = $tc->{arguments};
            my $pub2  = $bus->publish('tool_call',
                { toolCallId => $tc->{id}, name => $tc->{name}, input => $input });
            my ($blocked, $reason);
            for my $r (@{ $pub2->{results} }) {
                if (ref $r eq 'HASH' && $r->{block}) {
                    $blocked = 1; $reason = $r->{reason} // 'blocked by wit'; last;
                }
            }

            my ($output, $is_err);
            if ($blocked) {
                ($output, $is_err) = ("tool call blocked: $reason", 1);
                $self->{metrics}->inc('tools.blocked') if $self->{metrics};
            } else {
                my $tool = _find_tool($session, $tc->{name});
                unless ($tool) {
                    ($output, $is_err) = ("unknown tool: $tc->{name}", 1);
                    $self->{metrics}->inc('tools.unknown') if $self->{metrics};
                } else {
                    $bus->publish('tool_execution_start',
                        { toolCallId => $tc->{id}, name => $tc->{name}, input => $input });
                    my $res = $tool->run($input);
                    ($output, $is_err) = ($res->{output}, $res->{isError} ? 1 : 0);
                    $self->{metrics}->inc('tools.errors') if $self->{metrics} && $is_err;
                }
            }

            # tool_result hook: output/isError mutable (chained)
            my $tr = $bus->publish('tool_result',
                { toolCallId => $tc->{id}, name => $tc->{name}, output => $output, isError => $is_err });
            for my $r (@{ $tr->{results} }) {
                next unless ref $r eq 'HASH';
                $output = $r->{output}  if defined $r->{output};
                $is_err = $r->{isError} ? 1 : 0 if defined $r->{isError};
            }

            $bus->publish('tool_execution_end',
                { toolCallId => $tc->{id}, name => $tc->{name}, isError => $is_err });
            $session->add_tool_result($tc->{id}, $output, $is_err);
        }

        $bus->publish('turn_end', { turn => $turn });
        $self->{tracer}->end_span($turn_span) if $self->{tracer} && $turn_span;

        # Compaction threshold check between turns (Pi semantics).
        if ($self->{compactor}) {
            my $est = $session->est_context_tokens;
            if ($self->{compactor}->should_compact($est)) {
                eval {
                    $self->{compactor}->compact(
                        store => $session->store, session_id => $session->id,
                        provider => $session->provider, bus => $bus,
                    );
                };
                warn "[compaction] failed: $@" if $@;
            }
        }
    }

    $bus->publish('agent_end',     {});
    $bus->publish('agent_settled', {});
    $self->{tracer}->end_span($agent_span) if $self->{tracer} && $agent_span;
    $self->{metrics}->flush if $self->{metrics};

    if ($last_error) {
        return { ok => 0, error => $last_error, turns => $turn };
    }
    return { ok => 1, turns => $turn };
}

# ---------------------------------------------------------------------------
# Provider call: non-streaming by default; streaming aggregates deltas.
# ---------------------------------------------------------------------------
sub _provider_call {
    my ($self, $payload) = @_;
    my $p = $self->_provider;

    unless ($self->{stream}) {
        return $p->post_json('/chat/completions', $payload);
    }

    # streaming: aggregate text + indexed tool_call fragments
    my %agg = ( content => '', tool_calls => {} );
    my $finish;
    $p->stream_chat(
        messages => [ map { _plain($_) } @{ $payload->{messages} // [] } ],
        tools    => $payload->{tools},
        on_delta => sub {
            my ($d) = @_;
            $agg{content} .= $d->{text} if defined $d->{text};
            for my $tc (@{ $d->{tool_calls} // [] }) {
                my $i  = $tc->{index} // 0;
                my $slot = $agg{tool_calls}{$i} //= { id => '', function => { name => '', arguments => '' } };
                $slot->{id}   = $tc->{id}                 if defined $tc->{id};
                $slot->{function}{name}      .= ($tc->{function}{name} // '');
                $slot->{function}{arguments} .= ($tc->{function}{arguments} // '');
            }
            $self->_bus->publish('message_update', { delta => $d });
        },
    );
    my @tcs = map {
        my $s = $agg{tool_calls}{$_};
        +{ id => $s->{id}, type => 'function',
           function => { name => $s->{function}{name}, arguments => $s->{function}{arguments} } };
    } sort { $a <=> $b } keys %{ $agg{tool_calls} };
    return { choices => [ { finish_reason => 'stop', message => { content => $agg{content}, tool_calls => \@tcs } } ] };
}

# streaming endpoint takes plain role/content messages; strip tool_calls shape
sub _plain {
    my ($m) = @_;
    if (($m->{role} // '') eq 'assistant' && ref $m->{tool_calls} eq 'ARRAY') {
        return { %$m };   # keep as-is (provider accepts it)
    }
    return { role => $m->{role}, content => $m->{content} // '' };
}

sub _find_tool {
    my ($session, $name) = @_;
    for my $t (@{ $session->{tools} }) {
        return $t if $t->{name} eq $name;
    }
    return undef;
}

# ---------------------------------------------------------------------------
# Subagent spawning: create a child loop with its own session, shared bus/store.
# ---------------------------------------------------------------------------

# Spawn a subagent that runs a prompt in an isolated session.
# Returns { ok, output, session_id, turns } on completion.
sub spawn {
    my ($self, %args) = @_;
    my $prompt = $args{prompt} or die "spawn requires prompt\n";
    my $bus    = $self->_bus;
    my $store  = $self->{session}{store};
    my $parent = $self->{session};

    # Create child session with same store/bus/provider but new ID.
    require Clam::Session;
    my $child_session = Clam::Session->new(
        store    => $store,
        bus      => $bus,
        provider => $parent->{provider},
        name     => $args{name} // "subagent_" . time(),
    );

    # Copy tools from parent to child.
    for my $tool ($parent->tools) {
        $child_session->add_tool($tool);
    }

    # Copy skills and context files.
    $child_session->{skills}        = [ @{ $parent->{skills}        // [] } ];
    $child_session->{context_files} = [ @{ $parent->{context_files} // [] } ];

    # Publish subagent.spawn event.
    $bus->publish('subagent.spawn', {
        parent_session_id => $parent->id,
        child_session_id  => $child_session->id,
        prompt            => $prompt,
    });

    # Create child loop with same primitives.
    my $child_loop = ref($self)->new(
        session   => $child_session,
        stream    => 0,   # subagents are non-streaming
        max_turns => $args{max_turns} // 30,
        governor  => $self->{governor},
        tracer    => $self->{tracer},
        cache     => $self->{cache},
        metrics   => $self->{metrics},
    );

    # Run the prompt.
    my $result = $child_loop->run_prompt($prompt);

    # Publish subagent.done event.
    $bus->publish('subagent.done', {
        parent_session_id => $parent->id,
        child_session_id  => $child_session->id,
        ok                => $result->{ok},
        turns             => $result->{turns},
        error             => $result->{error},
    });

    # Return child's last assistant message as output.
    my $output = '';
    if ($result->{ok}) {
        my $leaf = $store->get_message($store->leaf_message($child_session->id));
        if ($leaf && $leaf->{role} eq 'assistant' && ref $leaf->{content} eq 'HASH') {
            $output = $leaf->{content}{text} // '';
        }
    }

    return {
        ok         => $result->{ok},
        output     => $output,
        session_id => $child_session->id,
        turns      => $result->{turns},
        error      => $result->{error},
    };
}

1;
