# Clank::Rules::BehaviorTree — modular behavior trees.
# Nodes: Sequence, Selector, Parallel, Action, Condition, Inverter, Repeater,
# Succeeder, Failer. Each tick evaluates top-to-bottom, left-to-right.
# Nodes return: SUCCESS, FAILURE, or RUNNING. A shared blackboard hashref is
# threaded through every node via $context->{blackboard}.
package Clank::Rules::BehaviorTree;
use strict;
use warnings;

# Node statuses.
use constant SUCCESS => 'SUCCESS';
use constant FAILURE => 'FAILURE';
use constant RUNNING => 'RUNNING';

# Create a new BehaviorTree from a definition hashref (see _build_node).
sub new {
    my ($class, %args) = @_;
    my $def  = $args{tree} // {};
    my $root = _build_node($def);
    return bless {
        root       => $root,
        name       => $args{name} // 'unnamed',
        blackboard => {},   # shared state between nodes
    }, $class;
}

# Tick the tree from root. Returns node status (SUCCESS|FAILURE|RUNNING).
sub tick {
    my ($self, $context) = @_;
    $context //= {};
    $context->{blackboard} = $self->{blackboard};
    return $self->{root}->($context);
}

# Get the tree structure as a hashref (compiled nodes are closures).
sub dump {
    my ($self) = @_;
    return _dump_node($self->{root});
}

# === Node Builders ===

sub _build_node {
    my ($def) = @_;
    return sub { SUCCESS } unless ref $def eq 'HASH';

    my $type = $def->{type} // 'action';

    if ($type eq 'sequence') {
        return _build_sequence($def->{children} // []);
    }
    elsif ($type eq 'selector') {
        return _build_selector($def->{children} // []);
    }
    elsif ($type eq 'parallel') {
        return _build_parallel($def->{children} // [], $def->{threshold} // 1);
    }
    elsif ($type eq 'action') {
        return _build_action($def);
    }
    elsif ($type eq 'condition') {
        return _build_condition($def);
    }
    elsif ($type eq 'inverter') {
        return _build_inverter($def->{child});
    }
    elsif ($type eq 'repeater') {
        return _build_repeater($def->{child}, $def->{times} // -1);
    }
    elsif ($type eq 'succeeder') {
        return sub { SUCCESS };
    }
    elsif ($type eq 'failer') {
        return sub { FAILURE };
    }

    return sub { SUCCESS };
}

# Sequence: run children until one fails.
sub _build_sequence {
    my ($children) = @_;
    my @nodes = map { _build_node($_) } @$children;
    return sub {
        my ($ctx) = @_;
        for my $node (@nodes) {
            my $status = $node->($ctx);
            return $status if $status ne SUCCESS;
        }
        return SUCCESS;
    };
}

# Selector: run children until one succeeds.
sub _build_selector {
    my ($children) = @_;
    my @nodes = map { _build_node($_) } @$children;
    return sub {
        my ($ctx) = @_;
        for my $node (@nodes) {
            my $status = $node->($ctx);
            return $status if $status ne FAILURE;
        }
        return FAILURE;
    };
}

# Parallel: run all children, succeed if >= threshold pass.
sub _build_parallel {
    my ($children, $threshold) = @_;
    my @nodes = map { _build_node($_) } @$children;
    return sub {
        my ($ctx) = @_;
        my $passed = 0;
        for my $node (@nodes) {
            my $status = $node->($ctx);
            $passed++ if $status eq SUCCESS;
        }
        return $passed >= $threshold ? SUCCESS : FAILURE;
    };
}

# Action: execute a code ref. A defined non-status return is passed through.
sub _build_action {
    my ($def) = @_;
    my $code = $def->{code};
    return sub {
        my ($ctx) = @_;
        if (ref $code eq 'CODE') {
            my $result = $code->($ctx);
            return $result if defined $result;
            return SUCCESS;
        }
        return SUCCESS;
    };
}

# Condition: evaluate a predicate.
sub _build_condition {
    my ($def) = @_;
    my $code = $def->{code};
    return sub {
        my ($ctx) = @_;
        if (ref $code eq 'CODE') {
            return $code->($ctx) ? SUCCESS : FAILURE;
        }
        return FAILURE;
    };
}

# Inverter: flip child's result.
sub _build_inverter {
    my ($child_def) = @_;
    my $child = _build_node($child_def);
    return sub {
        my ($ctx) = @_;
        my $status  = $child->($ctx);
        return SUCCESS if $status eq FAILURE;
        return FAILURE if $status eq SUCCESS;
        return RUNNING;
    };
}

# Repeater: run child N times (-1 = until failure).
sub _build_repeater {
    my ($child_def, $times) = @_;
    my $child = _build_node($child_def);
    return sub {
        my ($ctx)   = @_;
        my $count   = 0;
        while ($times < 0 || $count < $times) {
            my $status = $child->($ctx);
            return RUNNING if $status eq RUNNING;
            $count++;
            last if $status eq FAILURE && $times < 0;
        }
        return SUCCESS;
    };
}

# === Dump ===

sub _dump_node {
    my ($node) = @_;
    # Can't introspect closures, return placeholder.
    return { type => 'closure', desc => 'compiled node' };
}

# === Convenience constructors (return definition hashrefs) ===

sub sequence {
    my (@children) = @_;
    return { type => 'sequence', children => \@children };
}

sub selector {
    my (@children) = @_;
    return { type => 'selector', children => \@children };
}

sub action (&) {
    my ($code) = @_;
    return { type => 'action', code => $code };
}

sub condition (&) {
    my ($code) = @_;
    return { type => 'condition', code => $code };
}

1;
