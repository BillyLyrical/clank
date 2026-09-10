# Self-evolution loop for procedural graphs.
# Four-step cycle: diagnostic rollout → mutation → validation gate → rejection memory.
# Mirrors Crystallizer's pattern but operates on graph topology.
package Clank::ProceduralGraph::Evolver;
use strict;
use warnings;
use Clank::Util qw(now_ms jencode jdecode);

sub new {
    my ($class, %args) = @_;
    my $pg = $args{pg} or die "Evolver requires pg";
    my $store = $args{store} or die "Evolver requires store";

    return bless {
        pg       => $pg,
        store    => $store,
        provider => $args{provider},   # LLM for refiner calls
        verbose  => $args{verbose} // 0,
    }, $class;
}

sub dbh { $_[0]->{store}->dbh }

# ---------------------------------------------------------------------------
# Step 1: Diagnostic Rollout
# ---------------------------------------------------------------------------
# Run evaluator on training tasks, collect { query, trajectory, score }.
# Evaluator sub receives (query) and returns { ok, trajectory }.

sub run_tasks {
    my ($self, %args) = @_;
    my $tasks = $args{tasks} or die "run_tasks requires tasks";
    my $evaluator = $args{evaluator} or die "run_tasks requires evaluator";

    my @results;
    for my $task (@$tasks) {
        my $query = ref $task eq 'HASH' ? ($task->{query} // $task->{prompt} // '') : "$task";
        my $expected = ref $task eq 'HASH' ? $task->{expected} : undef;

        my $res = eval { $evaluator->($query) };
        my $trajectory = $res->{trajectory} // [];
        my $score = $res->{score} // ($res->{ok} ? 1.0 : 0.0);

        push @results, {
            query      => $query,
            expected   => $expected,
            trajectory => $trajectory,
            score      => $score,
        };
    }
    return \@results;
}

# Partition results into successes and failures by score threshold.
sub partition {
    my ($self, $results, %args) = @_;
    my $threshold = $args{threshold} // 0.5;

    my (@successes, @failures);
    for my $r (@$results) {
        if ($r->{score} >= $threshold) {
            push @successes, $r;
        } else {
            push @failures, $r;
        }
    }
    return { successes => \@successes, @failures ? (failures => \@failures) : () };
}

# ---------------------------------------------------------------------------
# Step 2: Feedback-Driven Mutation
# ---------------------------------------------------------------------------
# LLM refiner analyzes trajectories and proposes graph mutations.

sub propose_mutations {
    my ($self, %args) = @_;
    my $successes = $args{successes} // [];
    my $failures  = $args{failures}  // [];
    my $rejections = $args{rejections} // [];

    my $graph_hash = $self->{pg}->to_hash;
    my $graph_text = $self->_serialize_graph($graph_hash);

    my $success_text = $self->_serialize_trajectories($successes, 'SUCCESS');
    my $failure_text = $self->_serialize_trajectories($failures, 'FAILURE');
    my $rejection_text = $self->_serialize_rejections($rejections);

    my $prompt = <<"END_PROMPT";
You are a procedural graph refiner. Analyze agent execution trajectories and propose improvements to the procedural graph.

CURRENT GRAPH:
$graph_text

$rejection_text

$success_text

$failure_text

Based on this analysis, propose mutations to improve the graph. Focus on:
1. Missing transitions that would prevent failure loops
2. Edges that steer agents toward repeated errors
3. Attribute revisions that clarify ambiguous guidance
4. Pruning edges that encourage wrong behavior

Return ONLY a JSON object with a "mutations" array. Each mutation is one of:
  {"op": "add_node", "node": {"id": "...", "label": "...", "description": "...", "node_type": "procedure"}}
  {"op": "add_edge", "edge": {"source_id": "...", "target_id": "...", "relation": "...", "attributes": {"condition": "...", "guidance": "...", "pitfalls": "..."}}}
  {"op": "delete_edge", "edge_id": "..."}
  {"op": "revise_edge", "edge_id": "...", "attributes": {"condition": "...", "guidance": "...", "pitfalls": "..."}}

If no useful mutations, return {"mutations": []}.
END_PROMPT

    my $response_text = $self->_llm_call($prompt);
    return $self->_parse_mutations($response_text);
}

# ---------------------------------------------------------------------------
# Step 3: Apply Mutations
# ---------------------------------------------------------------------------

sub apply_mutations {
    my ($self, $mutations) = @_;
    my @applied;
    my @errors;

    for my $m (@$mutations) {
        my $op = $m->{op} // '';
        eval {
            if ($op eq 'add_node') {
                my $n = $m->{node} or die "add_node missing node";
                $self->{pg}->add_node(
                    id          => $n->{id},
                    label       => $n->{label} // $n->{id},
                    description => $n->{description},
                    node_type   => $n->{node_type} // 'procedure',
                );
                push @applied, $m;
            }
            elsif ($op eq 'add_edge') {
                my $e = $m->{edge} or die "add_edge missing edge";
                $self->{pg}->add_edge(
                    source_id  => $e->{source_id},
                    target_id  => $e->{target_id},
                    relation   => $e->{relation} // 'LEADS_TO',
                    attributes => $e->{attributes} // {},
                );
                push @applied, $m;
            }
            elsif ($op eq 'delete_edge') {
                my $eid = $m->{edge_id} or die "delete_edge missing edge_id";
                $self->{pg}->delete_edge($eid);
                push @applied, $m;
            }
            elsif ($op eq 'revise_edge') {
                my $eid = $m->{edge_id} or die "revise_edge missing edge_id";
                my $attrs = $m->{attributes} or die "revise_edge missing attributes";
                $self->{pg}->update_edge($eid, attributes => $attrs);
                push @applied, $m;
            }
            else {
                die "unknown op: $op";
            }
        };
        if ($@) {
            push @errors, { mutation => $m, error => "$@" };
        }
    }

    return { applied => \@applied, errors => \@errors };
}

# ---------------------------------------------------------------------------
# Step 4: Validation Gate
# ---------------------------------------------------------------------------
# Evaluate candidate graph on held-out tasks. Accept if score >= baseline.

sub validate {
    my ($self, %args) = @_;
    my $tasks      = $args{tasks}      or die "validate requires tasks";
    my $evaluator  = $args{evaluator}  or die "validate requires evaluator";
    my $baseline   = $args{baseline};   # current graph's validation score

    my $results = $self->run_tasks(tasks => $tasks, evaluator => $evaluator);
    my $total = 0;
    my $sum = 0;
    for my $r (@$results) {
        $sum += $r->{score};
        $total++;
    }
    my $mean_score = $total > 0 ? $sum / $total : 0;

    my $accepted = 0;
    if (defined $baseline) {
        $accepted = ($mean_score >= $baseline) ? 1 : 0;
    } else {
        $accepted = 1;  # no baseline = accept
    }

    return {
        score    => $mean_score,
        baseline => $baseline,
        accepted => $accepted,
        n        => $total,
    };
}

# ---------------------------------------------------------------------------
# Rejection Memory
# ---------------------------------------------------------------------------

sub log_rejection {
    my ($self, %args) = @_;
    my $round     = $args{round}     // 0;
    my $mutation  = $args{mutation}  // '';
    my $val_score = $args{val_score};
    my $baseline  = $args{baseline};
    my $context   = $args{context};

    $self->dbh->do(
        'INSERT INTO pg_rejections (round, mutation, val_score, baseline, context, created_at)
         VALUES (?, ?, ?, ?, ?, ?)',
        undef,
        $round,
        ref $mutation eq 'HASH' ? jencode($mutation) : $mutation,
        $val_score,
        $baseline,
        ref $context eq 'HASH' ? jencode($context) : $context,
        now_ms(),
    );
}

sub get_rejections {
    my ($self, %args) = @_;
    my $round = $args{round};
    my $limit = $args{limit} // 20;

    my ($sql, @bind) = ('SELECT * FROM pg_rejections');
    if (defined $round) {
        $sql .= ' WHERE round <= ?';
        push @bind, $round;
    }
    $sql .= ' ORDER BY created_at DESC LIMIT ?';
    push @bind, $limit;

    my $rows = $self->dbh->selectall_arrayref($sql, { Slice => {} }, @bind);
    for my $r (@$rows) {
        $r->{mutation} = jdecode($r->{mutation} // '{}');
        $r->{context}  = jdecode($r->{context}  // '{}') if $r->{context};
    }
    return $rows;
}

# ---------------------------------------------------------------------------
# Evolution Log
# ---------------------------------------------------------------------------

sub log_evolution {
    my ($self, %args) = @_;
    $self->dbh->do(
        'INSERT INTO pg_evolution_log (round, mutation, candidate, train_score, val_score, committed, reason, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
        undef,
        $args{round}     // 0,
        ref $args{mutation} eq 'HASH' ? jencode($args{mutation}) : ($args{mutation} // ''),
        ref $args{candidate} eq 'HASH' ? jencode($args{candidate}) : ($args{candidate} // ''),
        $args{train_score},
        $args{val_score},
        $args{committed} ? 1 : 0,
        $args{reason} // '',
        now_ms(),
    );
}

sub get_evolution_log {
    my ($self, %args) = @_;
    my $round = $args{round};
    my $limit = $args{limit} // 50;

    my ($sql, @bind) = ('SELECT * FROM pg_evolution_log');
    if (defined $round) {
        $sql .= ' WHERE round = ?';
        push @bind, $round;
    }
    $sql .= ' ORDER BY id DESC LIMIT ?';
    push @bind, $limit;

    return $self->dbh->selectall_arrayref($sql, { Slice => {} }, @bind);
}

# ---------------------------------------------------------------------------
# Full Evolution Loop
# ---------------------------------------------------------------------------

sub evolve {
    my ($self, %args) = @_;
    my $train_tasks = $args{train_tasks} or die "evolve requires train_tasks";
    my $val_tasks   = $args{val_tasks}   or die "evolve requires val_tasks";
    my $evaluator   = $args{evaluator}   or die "evolve requires evaluator";
    my $max_rounds  = $args{max_rounds}  // 10;
    my $patience    = $args{patience}    // 3;

    my $best_score = 0;
    my $no_improve = 0;
    my @round_results;

    for my $round (1 .. $max_rounds) {
        # Step 1: Diagnostic rollout on training set
        my $train_results = $self->run_tasks(
            tasks     => $train_tasks,
            evaluator => $evaluator,
        );
        my $partition = $self->partition($train_results);

        my $train_score = 0;
        $train_score += $_->{score} for @$train_results;
        $train_score /= @$train_tasks if @$train_tasks;

        # Step 2: Propose mutations
        my $rejections = $self->get_rejections(round => $round - 1);
        my $mutations = $self->propose_mutations(
            successes  => $partition->{successes},
            failures   => $partition->{failures},
            rejections => $rejections,
        );

        unless (@$mutations) {
            push @round_results, { round => $round, status => 'no_mutations', train_score => $train_score };
            next;
        }

        # Snapshot before mutation
        my $snapshot = $self->{pg}->to_hash;

        # Step 3: Apply mutations
        my $applied = $self->apply_mutations($mutations);

        unless (@{$applied->{applied}}) {
            push @round_results, { round => $round, status => 'apply_failed', errors => $applied->{errors} };
            next;
        }

        # Step 4: Validate
        my $val = $self->validate(
            tasks     => $val_tasks,
            evaluator => $evaluator,
            baseline  => $best_score || undef,
        );

        my $committed = $val->{accepted};
        my $reason = $committed
            ? "val_score ($val->{score}) >= baseline ($best_score)"
            : "val_score ($val->{score}) < baseline ($best_score)";

        if ($committed) {
            $best_score = $val->{score};
            $no_improve = 0;
        } else {
            # Rollback: restore snapshot
            $self->{pg}->from_hash($snapshot);
            $no_improve++;

            # Log rejection
            $self->log_rejection(
                round     => $round,
                mutation  => { mutations => $mutations },
                val_score => $val->{score},
                baseline  => $best_score,
                context   => { applied => $applied->{applied} },
            );
        }

        # Log evolution round
        $self->log_evolution(
            round       => $round,
            mutation    => { mutations => $mutations },
            candidate   => $snapshot,
            train_score => $train_score,
            val_score   => $val->{score},
            committed   => $committed,
            reason      => $reason,
        );

        push @round_results, {
            round        => $round,
            status       => $committed ? 'evolved' : 'rolled_back',
            train_score  => $train_score,
            val_score    => $val->{score},
            mutations    => scalar @{$applied->{applied}},
            errors       => scalar @{$applied->{errors}},
        };

        last if $no_improve >= $patience;
    }

    return {
        rounds      => \@round_results,
        best_score  => $best_score,
        graph_stats => $self->{pg}->stats,
    };
}

# ---------------------------------------------------------------------------
# Private: LLM Interaction
# ---------------------------------------------------------------------------

sub _llm_call {
    my ($self, $prompt) = @_;
    my $provider = $self->{provider};
    return '{}' unless $provider;

    my $resp = eval {
        $provider->post_json('/chat/completions', {
            model    => $provider->{model},
            messages => [
                { role => 'system', content => 'You are a procedural graph analysis engine. Return only valid JSON.' },
                { role => 'user',   content => $prompt },
            ],
            temperature => 0,
            max_tokens  => 4096,
        });
    };

    if ($@ || !$resp) {
        warn "Evolver LLM call failed: $@" if $self->{verbose};
        return '{}';
    }

    my $choice = $resp->{choices}[0] // {};
    return $choice->{message}{content} // '{}';
}

# ---------------------------------------------------------------------------
# Private: Serialization Helpers
# ---------------------------------------------------------------------------

sub _serialize_graph {
    my ($self, $graph) = @_;
    my @lines;

    push @lines, "Nodes:";
    for my $n (@{$graph->{nodes} // []}) {
        push @lines, sprintf("  [%s] %s (%s) — %s",
            $n->{id}, $n->{label}, $n->{node_type} // 'procedure',
            $n->{description} // 'no description');
    }

    push @lines, "Edges:";
    for my $e (@{$graph->{edges} // []}) {
        my $a = $e->{attributes} // {};
        my $detail = '';
        $detail .= " condition=$a->{condition}" if $a->{condition};
        $detail .= " guidance=$a->{guidance}" if $a->{guidance};
        $detail .= " pitfalls=$a->{pitfalls}" if $a->{pitfalls};
        push @lines, sprintf("  %s --%s--> %s%s",
            $e->{source_id}, $e->{relation}, $e->{target_id}, $detail);
    }

    return join("\n", @lines);
}

sub _serialize_trajectories {
    my ($self, $trajectories, $label) = @_;
    return "No $label trajectories." unless @$trajectories;

    my @lines;
    push @lines, "$label TRAJECTORIES (" . scalar(@$trajectories) . "):";
    for my $t (@$trajectories) {
        push @lines, "";
        push @lines, "Query: $t->{query}";
        push @lines, "Score: $t->{score}";
        if (@{$t->{trajectory} // []}) {
            push @lines, "Steps:";
            for my $step (@{$t->{trajectory}}) {
                my $desc = ref $step eq 'HASH'
                    ? ($step->{action} // $step->{tool} // $step->{content} // '?')
                    : "$step";
                push @lines, "  - $desc";
            }
        }
    }
    return join("\n", @lines);
}

sub _serialize_rejections {
    my ($self, $rejections) = @_;
    return '' unless @$rejections;

    my @lines;
    push @lines, "REJECTED MUTATIONS (do not repeat these):";
    for my $r (@$rejections) {
        my $mut = $r->{mutation};
        if (ref $mut eq 'HASH' && ref $mut->{mutations} eq 'ARRAY') {
            for my $m (@{$mut->{mutations}}) {
                push @lines, "  - $m->{op}: " . jencode($m);
            }
        }
        push @lines, "    (val_score=$r->{val_score}, baseline=$r->{baseline})";
    }
    return join("\n", @lines);
}

sub _parse_mutations {
    my ($self, $text) = @_;
    return [] unless $text && length $text;

    # Extract JSON from response (may be wrapped in markdown code block)
    my $json = $text;
    if ($json =~ /```(?:json)?\s*\n?(.*?)\n?\s*```/s) {
        $json = $1;
    }

    my $data = eval { jdecode($json) };
    return [] unless ref $data eq 'HASH';
    return $data->{mutations} // [];
}

1;
