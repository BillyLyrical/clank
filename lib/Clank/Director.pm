# Clank::Director — multi-turn orchestration: plan, goal, force-tool.
#
# Sits between the user and the Loop. Takes a goal, decomposes it into
# subgoals via GoalPlanner, executes each subgoal through the Loop,
# and tracks progress. Replans on failure.
#
# Usage:
#   my $dir = Clank::Director->new(loop => $loop, world_model => $wm);
#   my $result = $dir->execute(goal => 'Refactor the auth module');
package Clank::Director;
use strict;
use warnings;
use Clank::Util qw(now_ms jencode jdecode);
use Clank::Logic::GoalPlanner;

sub new {
    my ($class, %args) = @_;
    my $loop = $args{loop} or die "Clank::Director requires loop\n";

    my $self = bless {
        loop        => $loop,
        world_model => $args{world_model},
        max_retries => $args{max_retries} // 2,
        metrics     => $args{metrics},
        tracer      => $args{tracer},
    }, $class;

    # Create GoalPlanner if world_model available.
    if ($self->{world_model}) {
        $self->{planner} = Clank::Logic::GoalPlanner->new(
            world_model => $self->{world_model},
            metrics     => $self->{metrics},
        );
    }

    return $self;
}

# Execute a goal. Returns { ok, goal_id, results, turns }.
sub execute {
    my ($self, %args) = @_;
    my $goal_text = $args{goal} or die "execute requires goal\n";
    my $subgoals  = $args{subgoals};   # optional: pre-defined subgoals
    my $max_turns = $args{max_turns} // 50;

    my $bus = $self->{loop}{session}{bus};
    my $total_turns = 0;

    # Create goal in planner.
    my $goal_id;
    if ($self->{planner}) {
        $goal_id = $self->{planner}->set_goal(
            statement => $goal_text,
            priority  => $args{priority} // 5,
        );
    }

    # If no subgoals provided, create a single subgoal for the whole goal.
    unless ($subgoals && @$subgoals) {
        $subgoals = [{ statement => $goal_text }];
    }

    # Add subgoals to planner.
    if ($self->{planner} && $goal_id) {
        for my $sg (@$subgoals) {
            $self->{planner}->add_subgoal(
                goal_id    => $goal_id,
                statement  => $sg->{statement},
                depends_on => $sg->{depends_on} // [],
            );
        }
    }

    # Execute each subgoal.
    my @results;
    my $all_ok = 1;

    for my $sg (@$subgoals) {
        my $sg_text = $sg->{statement};
        my $retries = 0;
        my $sg_ok = 0;

        while (!$sg_ok && $retries <= $self->{max_retries}) {
            # Build prompt for this subgoal.
            my $prompt = $self->_build_prompt($goal_text, $sg_text, \@results);

            # Run via Loop.
            my $result = $self->{loop}->run_prompt($prompt);
            $total_turns += $result->{turns} // 0;

            if ($result->{ok}) {
                # Get the output.
                my $store = $self->{loop}{session}{store};
                my $sid   = $self->{loop}{session}->id;
                my $leaf  = $store->get_message($store->leaf_message($sid));
                my $output = '';
                if ($leaf && $leaf->{role} eq 'assistant' && ref $leaf->{content} eq 'HASH') {
                    $output = $leaf->{content}{text} // '';
                }

                push @results, {
                    subgoal => $sg_text,
                    output  => $output,
                    ok      => 1,
                    turns   => $result->{turns},
                };
                $sg_ok = 1;

                # Mark subgoal complete in planner.
                if ($self->{planner} && $goal_id) {
                    $self->_mark_subgoal_complete($sg_text, $goal_id);
                }
            } else {
                $retries++;
                if ($retries > $self->{max_retries}) {
                    push @results, {
                        subgoal => $sg_text,
                        output  => $result->{error} // 'failed',
                        ok      => 0,
                        turns   => $result->{turns},
                    };
                    $all_ok = 0;
                }
            }
        }
    }

    # Mark goal complete if all subgoals succeeded.
    if ($self->{planner} && $goal_id && $all_ok) {
        $self->{planner}->complete_goal($goal_id);
    }

    # Publish director.done event.
    $bus->publish('director.done', {
        goal_id  => $goal_id,
        ok       => $all_ok,
        turns    => $total_turns,
        results  => scalar @results,
    }) if $bus;

    $self->{metrics}->inc('director.goals') if $self->{metrics};
    $self->{metrics}->inc('director.turns', $total_turns) if $self->{metrics};

    return {
        ok       => $all_ok,
        goal_id  => $goal_id,
        results  => \@results,
        turns    => $total_turns,
    };
}

# Build a prompt for a subgoal, including context from previous results.
sub _build_prompt {
    my ($self, $goal, $subgoal, $prev_results) = @_;

    my $prompt = "Goal: $goal\n\nCurrent task: $subgoal";

    if (@$prev_results) {
        $prompt .= "\n\nPrevious steps completed:";
        for my $r (@$prev_results) {
            my $status = $r->{ok} ? "done" : "FAILED";
            $prompt .= "\n- [$status] $r->{subgoal}";
        }
    }

    $prompt .= "\n\nExecute this task. When done, respond with what you accomplished.";
    return $prompt;
}

# Mark a subgoal as complete in the planner.
sub _mark_subgoal_complete {
    my ($self, $statement, $goal_id) = @_;
    my $planner = $self->{planner};

    # Find the subgoal by statement.
    my $subgoals = $planner->subgoals_for_goal($goal_id);
    for my $sg (@$subgoals) {
        if ($sg->{statement} eq $statement && $sg->{status} ne 'completed') {
            $planner->complete_subgoal($sg->{id});
            last;
        }
    }
}

1;
