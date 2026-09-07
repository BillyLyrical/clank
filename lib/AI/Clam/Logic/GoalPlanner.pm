# AI::Clam::Logic::GoalPlanner — goal decomposition and execution planning.
#
# Uses the WorldModel belief graph for relevance scoring: beliefs that
# are close to a goal in the dependency graph and have high confidence
# score highest. This drives which subgoals to pursue first.
#
# Pipeline:
#   1. Set goal → create goal entity in world model
#   2. Add subgoals with dependencies → link to beliefs
#   3. Score relevance → prioritize subgoals by belief proximity
#   4. Generate plan → topological sort of ready subgoals
#   5. Execute → mark subgoals complete → re-score dependents
package AI::Clam::Logic::GoalPlanner;
use strict;
use warnings;
use AI::Clam::Util qw(now_ms jencode jdecode);

sub new {
    my ($class, %args) = @_;
    my $world_model = $args{world_model} or die "AI::Clam::Logic::GoalPlanner requires world_model\n";

    my $self = bless {
        world_model => $world_model,
        dbh         => $world_model->{dbh},
        bus         => $args{bus},
        metrics     => $args{metrics},
    }, $class;
    $self->_init_schema;
    return $self;
}

sub _dbh { $_[0]->{dbh} }

sub _init_schema {
    my ($self) = @_;
    my $db = $self->_dbh;

    $db->do(qq{
CREATE TABLE IF NOT EXISTS goals (
    id          TEXT PRIMARY KEY,
    statement   TEXT NOT NULL,
    priority    INTEGER DEFAULT 5,
    status      TEXT DEFAULT 'active',
    parent_id   TEXT,
    created_at  INTEGER,
    updated_at  INTEGER
)});
    $db->do(qq{CREATE INDEX IF NOT EXISTS idx_goals_status ON goals(status)});

    $db->do(qq{
CREATE TABLE IF NOT EXISTS subgoals (
    id              TEXT PRIMARY KEY,
    goal_id         TEXT NOT NULL REFERENCES goals(id) ON DELETE CASCADE,
    statement       TEXT NOT NULL,
    status          TEXT DEFAULT 'pending',
    depends_on      TEXT,
    belief_id       INTEGER,
    relevance_score REAL DEFAULT 0,
    created_at      INTEGER,
    completed_at    INTEGER
)});
    $db->do(qq{CREATE INDEX IF NOT EXISTS idx_subgoals_goal ON subgoals(goal_id, status)});

    $db->do(qq{
CREATE TABLE IF NOT EXISTS goal_beliefs (
    goal_id    TEXT NOT NULL,
    belief_id  INTEGER NOT NULL,
    relevance  REAL DEFAULT 0,
    PRIMARY KEY (goal_id, belief_id)
)});
}

# === GOAL MANAGEMENT ===

sub set_goal {
    my ($self, %args) = @_;
    my $id = $args{id} || _gen_id();
    my $now = now_ms();

    $self->_dbh->do(
        'INSERT OR REPLACE INTO goals (id, statement, priority, status, parent_id, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, COALESCE((SELECT created_at FROM goals WHERE id = ?), ?), ?)',
        undef, $id, $args{statement}, $args{priority} // 5,
        $args{status} // 'active', $args{parent_id},
        $id, $now, $now,
    );

    # Also create as world model entity for cross-referencing.
    $self->{world_model}->add_entity(
        id   => "goal:$id",
        type => 'goal',
        name => $args{statement},
        attributes => { priority => $args{priority} // 5, status => $args{status} // 'active' },
    );

    $self->{metrics}->inc('goals.created') if $self->{metrics};
    return $id;
}

sub get_goal {
    my ($self, $id) = @_;
    return $self->_dbh->selectrow_hashref(
        'SELECT * FROM goals WHERE id = ?', undef, $id);
}

sub query_goals {
    my ($self, %args) = @_;
    my @where = ('1=1');
    my @bind;

    if (defined $args{status}) {
        push @where, 'status = ?';
        push @bind, $args{status};
    }
    if (defined $args{parent_id}) {
        push @where, 'parent_id = ?';
        push @bind, $args{parent_id};
    }

    my $sql = 'SELECT * FROM goals WHERE ' . join(' AND ', @where);
    $sql .= ' ORDER BY priority ASC, created_at DESC';
    $sql .= " LIMIT $args{limit}" if $args{limit};

    return $self->_dbh->selectall_arrayref($sql, { Slice => {} }, @bind);
}

sub complete_goal {
    my ($self, $id) = @_;
    my $now = now_ms();
    $self->_dbh->do(
        'UPDATE goals SET status = ?, updated_at = ? WHERE id = ?',
        undef, 'completed', $now, $id);
    $self->{metrics}->inc('goals.completed') if $self->{metrics};
}

sub abandon_goal {
    my ($self, $id) = @_;
    my $now = now_ms();
    $self->_dbh->do(
        'UPDATE goals SET status = ?, updated_at = ? WHERE id = ?',
        undef, 'abandoned', $now, $id);
}

# === SUBGOAL MANAGEMENT ===

sub add_subgoal {
    my ($self, %args) = @_;
    my $id = $args{id} || _gen_id();
    my $now = now_ms();
    my $deps = ref $args{depends_on} eq 'ARRAY' ? jencode($args{depends_on}) : '[]';

    $self->_dbh->do(
        'INSERT INTO subgoals (id, goal_id, statement, status, depends_on, belief_id, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?)',
        undef, $id, $args{goal_id}, $args{statement},
        $args{status} // 'pending', $deps, $args{belief_id},
        $now,
    );

    # Link to belief if provided.
    if ($args{belief_id}) {
        my $score = $self->_score_belief_for_goal($args{belief_id}, $args{goal_id});
        $self->_dbh->do(
            'INSERT OR REPLACE INTO goal_beliefs (goal_id, belief_id, relevance) VALUES (?, ?, ?)',
            undef, $args{goal_id}, $args{belief_id}, $score);
    }

    $self->{metrics}->inc('subgoals.created') if $self->{metrics};
    return $id;
}

sub get_subgoal {
    my ($self, $id) = @_;
    my $row = $self->_dbh->selectrow_hashref(
        'SELECT * FROM subgoals WHERE id = ?', undef, $id);
    return undef unless $row;
    $row->{depends_on} = jdecode($row->{depends_on} // '[]');
    return $row;
}

sub subgoals_for_goal {
    my ($self, $goal_id, %args) = @_;
    my $status = $args{status};

    my ($sql, @bind) = ('SELECT * FROM subgoals WHERE goal_id = ?', $goal_id);
    if ($status) {
        $sql .= ' AND status = ?';
        push @bind, $status;
    }
    $sql .= ' ORDER BY relevance_score DESC, created_at ASC';

    my $rows = $self->_dbh->selectall_arrayref($sql, { Slice => {} }, @bind);
    for my $r (@$rows) {
        $r->{depends_on} = jdecode($r->{depends_on} // '[]');
    }
    return $rows;
}

sub complete_subgoal {
    my ($self, $id) = @_;
    my $now = now_ms();
    $self->_dbh->do(
        'UPDATE subgoals SET status = ?, completed_at = ? WHERE id = ?',
        undef, 'completed', $now, $id);
    $self->{metrics}->inc('subgoals.completed') if $self->{metrics};

    # Check if any blocked subgoals become ready.
    my $sub = $self->get_subgoal($id);
    return unless $sub;

    my $siblings = $self->subgoals_for_goal($sub->{goal_id});
    for my $sib (@$siblings) {
        next if $sib->{status} ne 'blocked';
        next if $sib->{id} eq $id;
        if ($self->_deps_satisfied($sib)) {
            $self->_dbh->do(
                'UPDATE subgoals SET status = ? WHERE id = ?',
                undef, 'ready', $sib->{id});
        }
    }

    # Check if goal is fully complete.
    $self->_check_goal_completion($sub->{goal_id});
}

sub block_subgoal {
    my ($self, $id, $reason) = @_;
    $self->_dbh->do(
        'UPDATE subgoals SET status = ? WHERE id = ?',
        undef, 'blocked', $id);
}

# === RELEVANCE SCORING ===

# Score a belief's relevance to a goal based on graph distance and confidence.
# Formula: relevance = confidence / (1 + distance)
# Max relevance = 1.0 (belief IS the goal, distance=0, confidence=1.0)
sub score_beliefs_for_goal {
    my ($self, $goal_id, %args) = @_;
    my $max_depth = $args{max_depth} // 5;
    my $min_score = $args{min_score} // 0.05;

    # Get goal's linked belief IDs.
    my $goal_beliefs = $self->_dbh->selectall_arrayref(
        'SELECT belief_id FROM goal_beliefs WHERE goal_id = ?',
        { Slice => {} }, $goal_id);

    # Get all beliefs reachable from goal's beliefs (BFS).
    my %scored;
    for my $gb (@$goal_beliefs) {
        my $bid = $gb->{belief_id};
        next if $scored{$bid};

        # BFS from this belief.
        my %visited = ($bid => 0);
        my @queue = ($bid);

        while (@queue) {
            my $current = shift @queue;
            my $dist = $visited{$current};
            next if $dist >= $max_depth;

            # Get the belief's confidence.
            my $brow = $self->{world_model}->{dbh}->selectrow_hashref(
                'SELECT confidence, statement FROM wm_beliefs WHERE id = ? AND superseded_by IS NULL',
                undef, $current);
            next unless $brow;

            my $relevance = $brow->{confidence} / (1 + $dist);
            if ($relevance >= $min_score && (!exists $scored{$current} || $scored{$current} < $relevance)) {
                $scored{$current} = $relevance;
            }

            # Traverse both directions (dependents and sources).
            my $deps = $self->{world_model}->belief_dependents($current);
            for my $d (@$deps) {
                my $new_dist = $dist + 1;
                if (!exists $visited{$d->{to_id}} || $visited{$d->{to_id}} > $new_dist) {
                    $visited{$d->{to_id}} = $new_dist;
                    push @queue, $d->{to_id} if $new_dist < $max_depth;
                }
            }

            my $srcs = $self->{world_model}->belief_sources($current);
            for my $s (@$srcs) {
                my $new_dist = $dist + 1;
                if (!exists $visited{$s->{from_id}} || $visited{$s->{from_id}} > $new_dist) {
                    $visited{$s->{from_id}} = $new_dist;
                    push @queue, $s->{from_id} if $new_dist < $max_depth;
                }
            }
        }
    }

    # Store scores.
    my @results;
    for my $bid (keys %scored) {
        $self->_dbh->do(
            'INSERT OR REPLACE INTO goal_beliefs (goal_id, belief_id, relevance) VALUES (?, ?, ?)',
            undef, $goal_id, $bid, $scored{$bid});

        my $brow = $self->{world_model}->{dbh}->selectrow_hashref(
            'SELECT statement, confidence FROM wm_beliefs WHERE id = ?', undef, $bid);
        push @results, {
            belief_id  => $bid,
            statement  => $brow ? $brow->{statement} : '',
            confidence => $brow ? $brow->{confidence} : 0,
            relevance  => $scored{$bid},
        };
    }

    # Sort by relevance descending.
    @results = sort { $b->{relevance} <=> $a->{relevance} } @results;
    return \@results;
}

# Re-score all subgoals' relevance based on current belief graph.
sub rescore_subgoals {
    my ($self, $goal_id) = @_;
    my $subgoals = $self->subgoals_for_goal($goal_id);

    for my $sg (@$subgoals) {
        my $score = 0;
        if ($sg->{belief_id}) {
            $score = $self->_score_belief_for_goal($sg->{belief_id}, $goal_id);
        }
        $self->_dbh->do(
            'UPDATE subgoals SET relevance_score = ? WHERE id = ?',
            undef, $score, $sg->{id});
    }
}

# === PLAN GENERATION ===

# Generate an execution plan: topological sort of subgoals by dependencies.
# Returns arrayref of subgoals in execution order, with status flags.
sub plan {
    my ($self, $goal_id) = @_;
    my $subgoals = $self->subgoals_for_goal($goal_id);

    return [] unless @$subgoals;

    # Build adjacency list and in-degree count.
    my %by_id = map { $_->{id} => $_ } @$subgoals;
    my %in_degree;
    my %adj;   # parent => [children]

    for my $sg (@$subgoals) {
        $in_degree{$sg->{id}} //= 0;
        for my $dep (@{ $sg->{depends_on} }) {
            push @{ $adj{$dep} }, $sg->{id};
            $in_degree{$sg->{id}}++;
        }
    }

    # Kahn's algorithm for topological ordering.
    my @queue = sort {
        ($by_id{$b}{relevance_score} // 0) <=> ($by_id{$a}{relevance_score} // 0)
    } grep { $in_degree{$_} == 0 } keys %in_degree;

    my @plan;
    my %in_plan;
    my @order;   # topological order of IDs

    while (@queue) {
        my $id = shift @queue;
        next if $in_plan{$id};
        next unless $by_id{$id};

        push @order, $id;
        $in_plan{$id} = 1;

        for my $child (@{ $adj{$id} // [] }) {
            $in_degree{$child}--;
            if ($in_degree{$child} == 0) {
                push @queue, $child;
            }
        }
    }

    # Append remaining (cycles, disconnected).
    for my $sg (@$subgoals) {
        push @order, $sg->{id} unless $in_plan{$sg->{id}};
    }

    # Build plan with effective status.
    for my $id (@order) {
        my $sg = $by_id{$id};
        next unless $sg;

        my $effective_status = $sg->{status};
        if ($effective_status eq 'pending' || $effective_status eq 'ready') {
            my $deps_met = 1;
            for my $dep (@{ $sg->{depends_on} }) {
                my $dep_sg = $by_id{$dep};
                unless ($dep_sg && $dep_sg->{status} eq 'completed') {
                    $deps_met = 0;
                    last;
                }
            }
            $effective_status = $deps_met ? 'ready' : 'blocked';
        }

        push @plan, {
            id               => $sg->{id},
            statement        => $sg->{statement},
            status           => $sg->{status},
            effective_status => $effective_status,
            relevance_score  => $sg->{relevance_score} // 0,
            depends_on       => $sg->{depends_on},
            belief_id        => $sg->{belief_id},
        };
    }

    return \@plan;
}

# Next actionable subgoal: first 'ready' or 'active' subgoal in plan order.
sub next_subgoal {
    my ($self, $goal_id) = @_;
    my $plan = $self->plan($goal_id);

    for my $step (@$plan) {
        return $step if $step->{effective_status} eq 'ready'
                     || $step->{effective_status} eq 'active';
    }
    return undef;
}

# === GOAL-BELIEF LINKS ===

sub link_belief {
    my ($self, %args) = @_;
    my $score = $self->_score_belief_for_goal($args{belief_id}, $args{goal_id});
    $self->_dbh->do(
        'INSERT OR REPLACE INTO goal_beliefs (goal_id, belief_id, relevance) VALUES (?, ?, ?)',
        undef, $args{goal_id}, $args{belief_id}, $score);
    return $score;
}

sub linked_beliefs {
    my ($self, $goal_id) = @_;
    my $rows = $self->_dbh->selectall_arrayref(
        'SELECT gb.belief_id, gb.relevance, b.statement, b.confidence
         FROM goal_beliefs gb
         JOIN wm_beliefs b ON b.id = gb.belief_id
         WHERE gb.goal_id = ? AND b.superseded_by IS NULL
         ORDER BY gb.relevance DESC',
        { Slice => {} }, $goal_id);
    return $rows;
}

# === INTERNAL ===

sub _score_belief_for_goal {
    my ($self, $belief_id, $goal_id) = @_;

    # Check if there's a direct path in the belief graph.
    # Use the belief graph's BFS to find distance.
    my $graph = $self->{world_model}->belief_graph($belief_id, max_depth => 5);
    my %dist;
    for my $edge (@$graph) {
        $dist{$edge->{to}} = ($dist{$edge->{from}} // 0) + 1;
    }

    # Get belief confidence.
    my $brow = $self->{world_model}->{dbh}->selectrow_hashref(
        'SELECT confidence FROM wm_beliefs WHERE id = ?', undef, $belief_id);
    return 0 unless $brow;

    # If goal has a linked belief, score distance to it.
    my $goal_beliefs = $self->_dbh->selectall_arrayref(
        'SELECT belief_id FROM goal_beliefs WHERE goal_id = ?',
        { Slice => {} }, $goal_id);

    my $min_dist = 999;
    for my $gb (@$goal_beliefs) {
        my $d = $dist{$gb->{belief_id}} // 999;
        $min_dist = $d if $d < $min_dist;
    }

    # If no goal belief linkage yet, use a default distance.
    $min_dist = 3 if $min_dist == 999;

    return $brow->{confidence} / (1 + $min_dist);
}

sub _deps_satisfied {
    my ($self, $subgoal) = @_;
    my $deps = $subgoal->{depends_on};
    return 1 unless ref $deps eq 'ARRAY' && @$deps;

    for my $dep_id (@$deps) {
        my $dep = $self->get_subgoal($dep_id);
        return 0 unless $dep && $dep->{status} eq 'completed';
    }
    return 1;
}

sub _check_goal_completion {
    my ($self, $goal_id) = @_;
    my $pending = $self->_dbh->selectrow_array(
        'SELECT COUNT(*) FROM subgoals WHERE goal_id = ? AND status NOT IN (?)',
        undef, $goal_id, 'completed');
    if ($pending == 0) {
        my $all = $self->_dbh->selectrow_array(
            'SELECT COUNT(*) FROM subgoals WHERE goal_id = ?', undef, $goal_id);
        if ($all > 0) {
            $self->complete_goal($goal_id);
        }
    }
}

sub _gen_id {
    my @chars = ('a'..'z', '0'..'9');
    return join '', map { $chars[int(rand(@chars))] } 1..12;
}

1;
