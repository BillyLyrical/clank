# Clam::Constraints — output validation against philosophical and practical schemas.
#
# Registry pattern: each constraint is a named { name, desc, severity, fn } entry.
# validate() runs all enabled constraints against LLM output, returns violations.
# Hooks into message_end via bus; can also be called programmatically.
#
# Severity levels:
#   strict  — violation blocks emission, triggers LLM revision
#   warn    — violation logged but output passes through
#   ignore  — constraint disabled
#
# Philosophical constraints derived from minsky.txt taxonomy (AGI.md §6).
package Clam::Constraints;
use strict;
use warnings;
use Clam::Util qw(now_ms jencode);

sub new {
    my ($class, %args) = @_;
    my $self = bless {
        bus         => $args{bus},
        world_model => $args{world_model},
        tracer      => $args{tracer},
        metrics     => $args{metrics},
        schemas     => {},       # name => { name, desc, severity, fn }
        default_severity => $args{default_severity} // 'warn',
    }, $class;

    $self->_register_builtins;
    $self->_subscribe if $self->{bus};
    return $self;
}

# === REGISTRY ===

sub register {
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

sub unregister {
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

# Run all enabled constraints against $output. Returns arrayref of violations.
# Each violation: { schema, severity, message, detail }
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

# Are there any strict violations?
sub has_blocking_violations {
    my ($self, $violations) = @_;
    return scalar grep { $_->{severity} eq 'strict' } @$violations;
}

# Format violations for LLM revision prompt.
sub format_for_revision {
    my ($self, $violations) = @_;
    my @lines;
    for my $v (@$violations) {
        push @lines, sprintf("[%s] %s", $v->{schema}, $v->{message});
    }
    return join("\n", @lines);
}

# === BUS INTEGRATION ===

sub _subscribe {
    my ($self) = @_;
    $self->{bus}->subscribe('message_end', sub { $self->_on_message_end(@_) },
        name => 'constraints');
}

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

    # --- Philosophical constraints (AGI.md §6) ---

    # Stoic: separate controllable from uncontrollable.
    # Blocks promises of guaranteed outcomes.
    $self->register(
        name     => 'stoic_control',
        desc     => 'Output should not promise outcomes outside system control',
        severity => 'warn',
        fn       => sub {
            my ($output) = @_;
            my @v;
            if ($output =~ /\b(?:will guarantee|promise to ensure|definitely will|certainly will|guaranteed to)\b/i) {
                push @v, 'Promises outcomes outside system control';
            }
            if ($output =~ /\b(?:impossible to fail|cannot fail|will always work)\b/i) {
                push @v, 'Overclaims certainty of outcomes';
            }
            return @v;
        },
    );

    # Confucian: relational appropriateness (li).
    # Flags directive language toward perceived elders/superiors.
    $self->register(
        name     => 'confucian_li',
        desc     => 'Directive language toward elders or superiors is inappropriate',
        severity => 'ignore',   # off by default; culturally specific
        fn       => sub {
            my ($output, $context) = @_;
            my @v;
            if (($context->{user_role} // '') eq 'elder'
                && $output =~ /\byou should\b/i) {
                push @v, 'Directive language toward elder (confucian li)';
            }
            return @v;
        },
    );

    # Care ethics: attentiveness to emotional content.
    # Flags responses that ignore expressed distress.
    $self->register(
        name     => 'care_ethics',
        desc     => 'Response should acknowledge emotional content when present',
        severity => 'warn',
        fn       => sub {
            my ($output, $context) = @_;
            my @v;
            my $conversation = $context->{conversation} // '';
            if ($conversation =~ /\b(?:frustrated|angry|sad|upset|confused|lost|overwhelmed)\b/i
                && $output !~ /\b(?:understand|sorry|difficult|hard|feel|empathy|acknowledge)\b/i) {
                push @v, 'Ignores emotional content in conversation';
            }
            return @v;
        },
    );

    # Marx: alienation — output should not treat people as mere instruments.
    $self->register(
        name     => 'marx_alienation',
        desc     => 'Output should not reduce people to instruments or resources',
        severity => 'warn',
        fn       => sub {
            my ($output) = @_;
            my @v;
            if ($output =~ /\b(?:just fire them|replace the human|human?['']s?\s+(?:only|sole)\s+(?:purpose|value|role))\b/i) {
                push @v, 'Treats people as mere instruments (alienation)';
            }
            return @v;
        },
    );

    # Jung: shadow — output should not repress or deny negative aspects.
    $self->register(
        name     => 'jung_shadow',
        desc     => 'Output should not dismiss or suppress acknowledged problems',
        severity => 'warn',
        fn       => sub {
            my ($output) = @_;
            my @v;
            if ($output =~ /\b(?:just don'?t think about it|ignore the negative|there are no downsides|nothing can go wrong)\b/i) {
                push @v, 'Dismisses or represses negative aspects (shadow)';
            }
            return @v;
        },
    );

    # Freud: superego — output should not be excessively moralistic.
    $self->register(
        name     => 'freud_superego',
        desc     => 'Output should not be excessively moralistic or preachy',
        severity => 'warn',
        fn       => sub {
            my ($output) = @_;
            my @v;
            my $sentence_count = ($output =~ s/[.!?]+/[.!?]+/g) + 1;
            my $moral_count = () = $output =~ /\b(?:should|must|ought|duty|moral|virtue|righteous|sinful|wrong(?:ness)?|immoral)\b/gi;
            if ($sentence_count > 0 && $moral_count / $sentence_count > 0.3) {
                push @v, 'Excessively moralistic or preachy tone';
            }
            return @v;
        },
    );

    # --- Practical constraints ---

    # Vagueness: output is too vague to be useful.
    $self->register(
        name     => 'vagueness',
        desc     => 'Output should be specific rather than vague',
        severity => 'warn',
        fn       => sub {
            my ($output) = @_;
            my @v;
            # Check for excessive hedge words.
            my $hedge_count = () = $output =~ /\b(?:maybe|perhaps|possibly|might be|could be|sort of|kind of|it depends|generally|typically|usually)\b/gi;
            my @sentences = split /[.!?]+/, $output;
            my $count = scalar @sentences;
            if ($count > 0 && $hedge_count / $count > 0.4) {
                push @v, 'Output is excessively vague or hedging';
            }
            return @v;
        },
    );

    # Overclaiming: output claims certainty without evidence.
    $self->register(
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

    # Contradiction: output contradicts known world model facts.
    $self->register(
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
                # Allow optional words between negation and value (e.g. "is not a scripting language")
                if ($output =~ /(?:is not|isn't|are not|aren't|was not|wasn't)\s+\S*\s*\Q$value\E/i) {
                    push @v, "Contradicts known fact: $fact->{predicate} is $value";
                }
            }
            return @v;
        },
    );
}

1;

__END__

=head1 NAME

Clam::Constraints — output validation against philosophical and practical schemas.

=head1 SYNOPSIS

  use Clam::Constraints;

  my $c = Clam::Constraints->new(
      bus         => $bus,            # optional: auto-validate on message_end
      world_model => $wm,             # optional: for wm_contradiction check
      default_severity => 'warn',
  );

  # Validate output
  my $violations = $c->validate($llm_output, { conversation => $text });

  # Check for blocking violations
  if ($c->has_blocking_violations($violations)) {
      my $revision_prompt = $c->format_for_revision($violations);
  }

  # Register custom constraint
  $c->register(
      name     => 'no_jargon',
      desc     => 'Avoid technical jargon',
      severity => 'warn',
      fn       => sub { my ($output, $ctx) = @_; ... },
  );

=head1 DESCRIPTION

Registry of constraint schemas that validate LLM output before emission.
Each constraint is a named function that inspects the output and context,
returning a list of violation messages.

Philosophical constraints derive from the minsky.txt taxonomy (AGI.md section 6):
Stoic, Confucian, Care Ethics, Marx, Jung, Freud.

Practical constraints: vagueness, overclaiming, world model contradiction.

=head1 SEVERITY

=over 4

=item strict

Violation blocks emission. Triggers LLM revision request.

=item warn

Violation logged but output passes through.

=item ignore

Constraint disabled; skipped during validation.

=back

=head1 BUS INTEGRATION

When constructed with bus => $bus, subscribes to C<message_end> events.
If violations found, returns an assistant message with C<_violations> in content.

=cut
