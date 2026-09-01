# The agent loop. Every Pi extension event is a bus topic; wits subscribe and
# influence the run via per-topic reducer rules (see docs/DESIGN.md section 5).
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

    # 1) input hook: continue | transform | handled
    my $pub = $bus->publish('input', { text => $text, source => 'interactive' });
    my ($final_text, $handled_out) = ($text);
    for my $r (@{ $pub->{results} }) {
        next unless ref $r eq 'HASH';
        if (($r->{action} // '') eq 'transform' && defined $r->{text}) { $final_text = $r->{text} }
        elsif (($r->{action} // '') eq 'handled') { $handled_out = $r->{output}; last }
    }
    return { ok => 1, handled => 1, output => $handled_out } if defined $handled_out;

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
        $bus->publish('turn_start', { turn => $turn, session_id => $session->id });

        # 3) context hook: replace messages (chained across wits)
        my $msgs = $session->build_context;
        my $cx   = $bus->publish('context', { messages => $msgs, system_prompt => $sp });
        for my $r (@{ $cx->{results} }) {
            $msgs = $r->{messages} if ref $r eq 'HASH' && ref $r->{messages} eq 'ARRAY';
        }

        # 4) build provider payload; before_provider_request may replace it.
        # chat_payload returns a HASHREF — keep it as one (assigning it to a
        # list flattens nothing and yields a garbage single-key hash).
        my @schemas = map { $_->openai_schema } $session->tools;
        my $payload = $self->_provider->chat_payload(
            messages => [ { role => 'system', content => $sp }, @$msgs ],
            tools    => \@schemas,
        );
        delete $payload->{stream};
        my $bpr = $bus->publish('before_provider_request', { payload => $payload });
        for my $r (@{ $bpr->{results} }) {
            $payload = $r->{payload} if ref $r eq 'HASH' && ref $r->{payload} eq 'HASH';
        }

        # 5) provider call (streaming optional; deltas -> message_update events)
        my ($resp, $err);
        eval { $resp = $self->_provider_call($payload) };
        if ($@) {
            $last_error = "$@";
            $bus->publish('agent_end', { error => $last_error });
            return { ok => 0, error => $last_error, turns => $turn };
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
            } else {
                my $tool = _find_tool($session, $tc->{name});
                unless ($tool) {
                    ($output, $is_err) = ("unknown tool: $tc->{name}", 1);
                } else {
                    $bus->publish('tool_execution_start',
                        { toolCallId => $tc->{id}, name => $tc->{name}, input => $input });
                    my $res = $tool->run($input);
                    ($output, $is_err) = ($res->{output}, $res->{isError} ? 1 : 0);
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

1;
