# AI::Clam::Rules::DecisionTree — rule chains with branching. Each node names a
# rule in the engine; the rule's outcome selects the next branch.
# Trees persist to the shared store via kv (survive restarts, queryable).
package AI::Clam::Rules::DecisionTree;
use strict;
use warnings;

sub new {
    my ($class, %args) = @_;
    return bless {
        engine => $args{engine},   # AI::Clam::Rules::Engine
        nodes  => $args{nodes} // {},  # name => { rule, branches, default, action }
        root   => $args{root} // 'root',
    }, $class;
}

# Add a node: name, rule (name in engine), branches (outcome key → next node).
sub add_node {
    my ($self, $name, %opts) = @_;
    $self->{nodes}{$name} = {
        rule     => $opts{rule},        # rule name in the engine
        branches => $opts{branches} // {},  # { outcome_key => next_node_name }
        default  => $opts{default},     # fallback node if no branch matches
        action   => $opts{action},      # leaf action (sub ref)
    };
}

# Execute the tree from root. Returns { path, result, depth }.
sub execute {
    my ($self, $context) = @_;
    my @path;
    my $current = $self->{root};

    for my $depth (1 .. 20) {  # max depth guard
        my $node = $self->{nodes}{$current};
        last unless $node;

        push @path, $current;

        # Find and execute the node's rule. A named rule is looked up directly
        # so each node runs ITS rule (not whatever matches first engine-wide),
        # gated on its pattern actually matching. An unnamed internal node
        # (has branches) falls back to a priority search over the whole engine;
        # a pure leaf gets no outcome.
        my $outcome;
        if ($node->{rule}) {
            my $r = $self->{engine}->get_rule($node->{rule});
            $outcome = $r && $r->test($context) ? $r->execute($context) : undef;
        } elsif (%{ $node->{branches} // {} }) {
            my $r = $self->{engine}->find({ text => $context->{text} // '', node => $current });
            $outcome = $r ? $r->execute($context) : undef;
        }

        # Leaf node: return result.
        if ($node->{action}) {
            my $result = $node->{action}->($context, $outcome);
            return { path => \@path, result => $result, depth => $depth };
        }

        # Branch: select next node based on outcome keys.
        my $branches = $node->{branches} // {};
        my $next;
        if ($outcome && ref $outcome eq 'HASH') {
            for my $key (keys %$branches) {
                if (exists $outcome->{$key} && $outcome->{$key}) {
                    $next = $branches->{$key};
                    last;
                }
            }
        }
        $next //= $node->{default};
        last unless $next;

        $current = $next;
    }

    return { path => \@path, result => undef, depth => scalar @path };
}

# Load tree from the shared store (kv). Returns 1 on success.
sub load_from_store {
    my ($self, $store, $tree_id) = @_;
    my $data = $store->kv_get("decision_tree:$tree_id");
    return 0 unless ref $data eq 'HASH';
    $self->{nodes} = $data->{nodes} // {};
    $self->{root}  = $data->{root}  // 'root';
    return 1;
}

# Save tree to the shared store (kv). Note: leaf actions are code refs and do
# not serialize — they are stripped on save; a loaded tree must re-attach them.
sub save_to_store {
    my ($self, $store, $tree_id) = @_;
    my %serializable;
    for my $name (keys %{ $self->{nodes} }) {
        my %node = %{ $self->{nodes}{$name} };
        delete $node{action};   # code refs don't survive JSON
        $serializable{$name} = \%node;
    }
    $store->kv_set("decision_tree:$tree_id", { nodes => \%serializable, root => $self->{root} });
    return 1;
}

# Visualize tree structure.
sub visualize {
    my ($self, $node_name, $indent) = @_;
    $node_name //= $self->{root};
    $indent    //= 0;
    my $node = $self->{nodes}{$node_name};
    return "" unless $node;

    my $out = "  " x $indent . "$node_name";
    $out .= " [rule: $node->{rule}]" if $node->{rule};
    $out .= " *" if $node->{action};  # leaf marker
    $out .= "\n";

    for my $outcome (sort keys %{ $node->{branches} // {} }) {
        my $child = $node->{branches}{$outcome};
        $out .= "  " x ($indent + 1) . "-- $outcome -->\n";
        $out .= $self->visualize($child, $indent + 2);
    }

    if ($node->{default}) {
        $out .= "  " x ($indent + 1) . "-- default -->\n";
        $out .= $self->visualize($node->{default}, $indent + 2);
    }

    return $out;
}

1;
