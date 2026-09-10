# CLANK-WIT: name=ProceduralGraph
# CLANK-WIT: version=0.1.0
# CLANK-WIT: about=Procedural graph guidance for LLM agent execution
# CLANK-WIT: usage=Provides situational guidance from a procedural graph of (procedure, relation, procedure) triplets. Self-evolving via feedback.
# CLANK-WIT: hint=Procedural graph: what-to-do guidance, subgraph extraction, trajectory localization, graph editing tools, self-evolution
# CLANK-WIT: author=Clank
# CLANK-WIT: license=Artistic-2.0
package Clank::Wits::ProceduralGraph;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;

    my $store = $api->store;
    require Clank::ProceduralGraph;
    require Clank::ProceduralGraph::Evolver;
    my $pg = Clank::ProceduralGraph->new(store => $store);

    # Store pg instance for tool handlers and bus subscribers
    $api->{pg} = $pg;

    # --- Bus: procedural guidance context ---
    $api->on('context_procedural_guidance', sub {
        my ($ev) = @_;
        my $last_action = $ev->{payload}{last_action} // '';
        my $prompt      = $ev->{payload}{prompt} // '';

        my $node_id = $pg->localize($last_action);
        return { guidance => '' } unless $node_id;

        my $subgraph = $pg->extract_guidance_subgraph($node_id, 2);
        return { guidance => '' } unless $subgraph && @$subgraph;

        return { guidance => _format_guidance($node_id, $subgraph) };
    });

    # --- REPL commands ---

    $api->register_command('pg', description => 'procedural graph: /pg show|stats|reset|evolve', handler => sub {
        my ($ctx, $args) = @_;
        my ($subcmd, @rest) = split /\s+/, ($args // '');
        $subcmd //= 'show';

        if ($subcmd eq 'show') {
            return _cmd_show($pg);
        }
        elsif ($subcmd eq 'stats') {
            return _cmd_stats($pg);
        }
        elsif ($subcmd eq 'reset') {
            $pg->clear;
            return "procedural graph cleared";
        }
        elsif ($subcmd eq 'evolve') {
            return "usage: /pg evolve requires train_tasks, val_tasks, and evaluator (use pg_evolve tool instead)";
        }
        else {
            return "unknown subcommand: $subcmd (available: show, stats, reset, evolve)";
        }
    });

    # --- Tools: graph inspection and editing ---

    $api->register_tool(
        name        => 'pg_show_graph',
        description => 'Display the current procedural graph (nodes and edges)',
        parameters  => {
            type       => 'object',
            properties => {},
        },
        execute => sub {
            my ($args) = @_;
            return _result_show($pg);
        },
    );

    $api->register_tool(
        name        => 'pg_add_node',
        description => 'Add a node to the procedural graph',
        parameters  => {
            type       => 'object',
            properties => {
                id          => { type => 'string', description => 'Unique node id (auto-generated if omitted)' },
                label       => { type => 'string', description => 'Human-readable label' },
                description => { type => 'string', description => 'What this procedure does' },
                node_type   => { type => 'string', description => 'procedure, state, skill, or reasoning', default => 'procedure' },
            },
            required => ['label'],
        },
        execute => sub {
            my ($args) = @_;
            my $id = $pg->add_node(
                id          => $args->{id},
                label       => $args->{label},
                description => $args->{description},
                node_type   => $args->{node_type},
            );
            return { id => $id, ok => 1, message => "Node '$id' added" };
        },
    );

    $api->register_tool(
        name        => 'pg_add_edge',
        description => 'Add a directed edge to the procedural graph',
        parameters  => {
            type       => 'object',
            properties => {
                source_id  => { type => 'string', description => 'Source node id' },
                target_id  => { type => 'string', description => 'Target node id' },
                relation   => { type => 'string', description => 'Edge relation (e.g. LEADS_TO, REQUIRES, BLOCKS)' },
                condition  => { type => 'string', description => 'When this transition applies' },
                guidance   => { type => 'string', description => 'How to execute this transition' },
                pitfalls   => { type => 'string', description => 'What to avoid' },
            },
            required => ['source_id', 'target_id', 'relation'],
        },
        execute => sub {
            my ($args) = @_;
            my %attrs;
            $attrs{condition} = $args->{condition} if defined $args->{condition};
            $attrs{guidance}  = $args->{guidance}  if defined $args->{guidance};
            $attrs{pitfalls}  = $args->{pitfalls}  if defined $args->{pitfalls};

            my $id = $pg->add_edge(
                source_id => $args->{source_id},
                target_id => $args->{target_id},
                relation  => $args->{relation},
                attributes => \%attrs,
            );
            return { id => $id, ok => 1, message => "Edge '$args->{source_id}' --$args->{relation}--> '$args->{target_id}' added" };
        },
    );

    $api->register_tool(
        name        => 'pg_delete_edge',
        description => 'Remove an edge from the procedural graph',
        parameters  => {
            type       => 'object',
            properties => {
                edge_id => { type => 'string', description => 'Edge id to delete' },
            },
            required => ['edge_id'],
        },
        execute => sub {
            my ($args) = @_;
            my $ok = $pg->delete_edge($args->{edge_id});
            return { ok => $ok, message => $ok ? "Edge deleted" : "Edge not found" };
        },
    );

    $api->register_tool(
        name        => 'pg_delete_node',
        description => 'Remove a node from the procedural graph (soft-deletes incident edges)',
        parameters  => {
            type       => 'object',
            properties => {
                node_id => { type => 'string', description => 'Node id to delete' },
            },
            required => ['node_id'],
        },
        execute => sub {
            my ($args) = @_;
            my $ok = $pg->delete_node($args->{node_id});
            return { ok => $ok, message => $ok ? "Node deleted" : "Node not found" };
        },
    );

    $api->register_tool(
        name        => 'pg_stats',
        description => 'Show procedural graph statistics',
        parameters  => {
            type       => 'object',
            properties => {},
        },
        execute => sub {
            return $pg->stats;
        },
    );

    $api->register_tool(
        name        => 'pg_reset',
        description => 'Clear the entire procedural graph (nodes, edges, evolution history)',
        parameters  => {
            type       => 'object',
            properties => {},
        },
        execute => sub {
            $pg->clear;
            return { ok => 1, message => 'Procedural graph cleared' };
        },
    );

    $api->register_tool(
        name        => 'pg_evolve',
        description => 'Run one round of self-evolution on the procedural graph using execution feedback',
        parameters  => {
            type       => 'object',
            properties => {
                train_tasks => {
                    type        => 'string',
                    description => 'JSON array of training tasks: [{"query":"...","expected":"..."}]',
                },
                val_tasks => {
                    type        => 'string',
                    description => 'JSON array of validation tasks (held-out)',
                },
                max_rounds => {
                    type        => 'integer',
                    description => 'Maximum evolution rounds',
                    default     => 3,
                },
            },
            required => ['train_tasks', 'val_tasks'],
        },
        execute => sub {
            my ($args) = @_;
            require Clank::Util;
            my $train = Clank::Util::jdecode($args->{train_tasks} // '[]');
            my $val   = Clank::Util::jdecode($args->{val_tasks}   // '[]');

            return { error => 'train_tasks must be a JSON array' } unless ref $train eq 'ARRAY';
            return { error => 'val_tasks must be a JSON array' }   unless ref $val   eq 'ARRAY';
            return { error => 'train_tasks is empty' } unless @$train;

            my $provider;
            if ($api->session && $api->session->{provider}) {
                $provider = $api->session->{provider};
            }

            my $evolver = Clank::ProceduralGraph::Evolver->new(
                pg       => $pg,
                store    => $store,
                provider => $provider,
            );

            # Default evaluator: run agent loop on each query, score by success
            my $app = $api->{app};
            my $evaluator = sub {
                my ($query) = @_;
                return { ok => 0, score => 0, trajectory => [] } unless $app;

                my $result = eval {
                    $app->loop->run_prompt($query, session => $api->session);
                };
                my $ok = ($result && $result->{ok}) ? 1 : 0;
                return {
                    ok        => $ok,
                    score     => $ok ? 1.0 : 0.0,
                    trajectory => [ $result->{response} // '' ],
                };
            };

            my $ev_result = $evolver->evolve(
                train_tasks => $train,
                val_tasks   => $val,
                evaluator   => $evaluator,
                max_rounds  => $args->{max_rounds} // 3,
                patience    => 2,
            );

            return {
                ok          => 1,
                rounds      => scalar @{$ev_result->{rounds}},
                best_score  => $ev_result->{best_score},
                graph_stats => $ev_result->{graph_stats},
                history     => $ev_result->{rounds},
            };
        },
    );

    return $pg;
}

# ---------------------------------------------------------------------------
# REPL command helpers
# ---------------------------------------------------------------------------

sub _cmd_show {
    my ($pg) = @_;
    my $r = _result_show($pg);
    return $r->{message} // 'Graph is empty';
}

sub _result_show {
    my ($pg) = @_;
    my $nodes = $pg->all_nodes;
    my $edges = $pg->all_edges;

    return { nodes => 0, edges => 0, message => 'Graph is empty' } unless @$nodes;

    my @lines;
    push @lines, "NODES (" . scalar(@$nodes) . "):";
    for my $n (@$nodes) {
        push @lines, sprintf("  [%s] %s (%s) — %s",
            $n->{id}, $n->{label}, $n->{node_type},
            $n->{description} // 'no description');
    }

    push @lines, "";
    push @lines, "EDGES (" . scalar(@$edges) . "):";
    for my $e (@$edges) {
        my $attrs = $e->{attributes};
        my $detail = '';
        $detail .= " condition=$attrs->{condition}" if $attrs->{condition};
        $detail .= " guidance=$attrs->{guidance}" if $attrs->{guidance};
        $detail .= " pitfalls=$attrs->{pitfalls}" if $attrs->{pitfalls};
        push @lines, sprintf("  %s --%s--> %s%s",
            $e->{source_id}, $e->{relation}, $e->{target_id}, $detail);
    }

    return {
        nodes    => scalar @$nodes,
        edges    => scalar @$edges,
        graph    => join("\n", @lines),
        message  => join("\n", @lines),
    };
}

sub _cmd_stats {
    my ($pg) = @_;
    my $s = $pg->stats;
    return join("\n",
        "Procedural Graph Stats:",
        "  Nodes:          $s->{nodes}",
        "  Edges:          $s->{edges}",
        "  Disabled edges: $s->{disabled_edges}",
        "  Evolution rounds: $s->{evolution_rounds}",
    );
}

# ---------------------------------------------------------------------------
# Format subgraph as guidance text
# ---------------------------------------------------------------------------

sub _format_guidance {
    my ($node_id, $edges) = @_;
    return '' unless @$edges;

    my @lines;
    push @lines, "[procedural guidance]";
    push @lines, "Active procedure: $node_id";
    push @lines, "";
    push @lines, "Available transitions:";

    for my $e (@$edges) {
        my $target = $e->{target_label} // $e->{target_id};
        my $rel    = $e->{relation};
        my $attrs  = $e->{attributes};

        push @lines, "";
        push @lines, "  -> $target ($rel)";
        push @lines, "     condition: $attrs->{condition}" if $attrs->{condition};
        push @lines, "     guidance:  $attrs->{guidance}"  if $attrs->{guidance};
        push @lines, "     pitfalls:  $attrs->{pitfalls}"  if $attrs->{pitfalls};
    }

    push @lines, "";
    push @lines, "[/procedural guidance]";
    return join("\n", @lines);
}

1;
