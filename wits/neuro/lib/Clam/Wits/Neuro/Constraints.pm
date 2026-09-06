# CLAM-WIT: name=Constraints
# CLAM-WIT: version=1.0.0
# CLAM-WIT: about=Output validation — checks LLM output against practical schemas before emission
# CLAM-WIT: usage=Auto-validates on message_end bus event. Register custom constraints via API.
# CLAM-WIT: hint=constraints, validation, output quality, contradiction detection
# CLAM-WIT: author=CLAM
# CLAM-WIT: license=Artistic-2.0
#
# Registry pattern: each constraint is a named { name, desc, severity, fn } entry.
# validate() runs all enabled constraints against LLM output, returns violations.
# Severity: strict (blocks), warn (logs), ignore (skipped).
package Clam::Wits::Neuro::Constraints;
use strict;
use warnings;
use Clam::Util qw(now_ms jencode);

sub new {
    my ($class, %args) = @_;
    my $self = bless {
        schemas     => {},
        world_model => $args{world_model},
        tracer      => $args{tracer},
        metrics     => $args{metrics},
        default_severity => $args{default_severity} // 'warn',
    }, $class;
    $self->_register_builtins;
    return $self;
}

sub register {
    my ($self, $api) = @_;
    $self->{api} = $api;

    # Lazily create WorldModel from same store (shared SQLite tables).
    unless ($self->{world_model}) {
        eval {
            require Clam::WorldModel;
            $self->{world_model} = Clam::WorldModel->new(store => $api->store);
        };
    }

    # Subscribe to message_end for output validation.
    $api->on('message_end', sub { $self->_on_message_end(@_) });

    return $self;
}

# === REGISTRY ===

sub add_constraint {
    my ($self, %args) = @_;
    my $name = $args{name} or die "Constraint requires name\n";
    my $fn   = $args{fn}   or die "Constraint '$name' requires fn\n";
    $self->{schemas}{$name} = {
        name     => $name,
        desc     => $args{desc} // '',
        severity => $args{severity} // $self->{default_severity},
        fn       => $fn,
    };
    return $self;
}

sub remove_constraint {
    my ($self, $name) = @_;
    delete $self->{schemas}{$name};
}

sub set_severity {
    my ($self, $name, $severity) = @_;
    return unless exists $self->{schemas}{$name};
    $self->{schemas}{$name}{severity} = $severity;
}

sub list_schemas {
    my ($self) = @_;
    return [
        sort { $a->{name} cmp $b->{name} }
        map  { $self->{schemas}{$_} }
        keys %{$self->{schemas}}
    ];
}

# === VALIDATION ===

sub validate {
    my ($self, $output, $context) = @_;
    $context //= {};
    my @violations;

    for my $name (sort keys %{$self->{schemas}}) {
        my $s = $self->{schemas}{$name};
        next if $s->{severity} eq 'ignore';

        my @v = eval { $s->{fn}->($output, $context, $self) };
        if ($@) {
            push @violations, {
                schema   => $name,
                severity => 'warn',
                message  => "constraint '$name' threw: $@",
            };
            next;
        }
        for my $v (@v) {
            push @violations, {
                schema   => $name,
                severity => $s->{severity},
                message  => $v,
            };
        }
    }

    $self->{metrics}->inc('constraints.checked') if $self->{metrics};
    $self->{metrics}->inc('constraints.violations', scalar @violations)
        if $self->{metrics} && @violations;

    return \@violations;
}

sub has_blocking_violations {
    my ($self, $violations) = @_;
    return scalar grep { $_->{severity} eq 'strict' } @$violations;
}

sub format_for_revision {
    my ($self, $violations) = @_;
    my @lines;
    for my $v (@$violations) {
        push @lines, sprintf("[%s] %s", $v->{schema}, $v->{message});
    }
    return join("\n", @lines);
}

# === BUS HANDLER ===

sub _on_message_end {
    my ($self, $ev) = @_;
    my $content = $ev->{payload}{content}{text} // '';
    return unless length $content;

    my $trace_id;
    $trace_id = $self->{tracer}->start_span('constraints.validate', topic => 'constraints')
        if $self->{tracer};

    my $violations = $self->validate($content, {
        session_id => $ev->{payload}{session_id},
    });

    if ($self->{tracer} && defined $trace_id) {
        $self->{tracer}->end_span($trace_id);
    }

    return unless @$violations;

    return {
        role    => 'assistant',
        content => {
            text         => $content,
            tool_calls   => [],
            _violations  => $violations,
        },
    };
}

# === BUILT-IN CONSTRAINTS ===

sub _register_builtins {
    my ($self) = @_;

    $self->add_constraint(
        name     => 'vagueness',
        desc     => 'Output should be specific rather than vague',
        severity => 'warn',
        fn       => sub {
            my ($output) = @_;
            my @v;
            my $hedge_count = () = $output =~ /\b(?:maybe|perhaps|possibly|might be|could be|sort of|kind of|it depends|generally|typically|usually)\b/gi;
            my @sentences = split /[.!?]+/, $output;
            my $count = scalar @sentences;
            if ($count > 0 && $hedge_count / $count > 0.4) {
                push @v, 'Output is excessively vague or hedging';
            }
            return @v;
        },
    );

    $self->add_constraint(
        name     => 'overclaiming',
        desc     => 'Output should not claim absolute certainty without evidence',
        severity => 'warn',
        fn       => sub {
            my ($output, $context) = @_;
            my @v;
            if ($output =~ /\b(?:always|never|every single|without exception|100%|absolutely|undeniably|unquestionably)\b/i
                && !($context->{has_evidence} // 0)) {
                push @v, 'Claims absolute certainty without stated evidence';
            }
            return @v;
        },
    );

    $self->add_constraint(
        name     => 'wm_contradiction',
        desc     => 'Output should not contradict known world model facts',
        severity => 'strict',
        fn       => sub {
            my ($output, $context, $self_obj) = @_;
            my @v;
            my $wm = $self_obj->{world_model} // $context->{world_model};
            return @v unless $wm;

            my $facts = eval { $wm->query_facts() } // [];
            for my $fact (@$facts) {
                my $value = lc($fact->{value} // '');
                next unless length $value;
                if ($output =~ /(?:is not|isn't|are not|aren't|was not|wasn't)\s+\S*\s*\Q$value\E/i) {
                    push @v, "Contradicts known fact: $fact->{predicate} is $value";
                }
            }
            return @v;
        },
    );
}

1;
