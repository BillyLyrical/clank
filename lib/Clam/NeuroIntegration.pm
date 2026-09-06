# Clam::NeuroIntegration — bidirectional LLM <-> world model integration.
#
# Three phases:
#   Phase 1: LLM reads world model (inject relevant facts into context)
#   Phase 2: Rules validate LLM output (catch contradictions)
#   Phase 3: LLM updates world model (extract knowledge from conversation)
#
# Hooks into the Loop via bus events. No changes to Loop.pm needed.
package Clam::NeuroIntegration;
use strict;
use warnings;
use Clam::Util qw(jencode jdecode);

sub new {
    my ($class, %args) = @_;
    my $store = $args{store} // die "Clam::NeuroIntegration requires store\n";
    my $bus   = $args{bus}   // die "Clam::NeuroIntegration requires bus\n";

    my $self = bless {
        store       => $store,
        bus         => $bus,
        world_model => $args{world_model},
        rules       => $args{rules},
        provider    => $args{provider},
        tracer      => $args{tracer},
        metrics     => $args{metrics},
        max_facts   => $args{max_facts} // 20,
        validate    => $args{validate} // 1,      # enable rule validation
        extract     => $args{extract}  // 1,      # enable knowledge extraction
    }, $class;

    $self->_subscribe;
    return $self;
}

sub _subscribe {
    my ($self) = @_;
    my $bus = $self->{bus};

    # Phase 1: inject world model context before LLM generates.
    $bus->subscribe('context', sub { $self->_on_context(@_) }, name => 'neuro.context');

    # Phase 2: validate LLM output after generation.
    $bus->subscribe('message_end', sub { $self->_on_message_end(@_) }, name => 'neuro.validate');

    # Phase 3: extract knowledge after conversation ends.
    $bus->subscribe('agent_end', sub { $self->_on_agent_end(@_) }, name => 'neuro.extract');
}

# === PHASE 1: LLM reads world model ===

sub _on_context {
    my ($self, $ev) = @_;
    return unless $self->{world_model};

    my $trace_id;
    $trace_id = $self->{tracer}->start_span('neuro.context_inject', topic => 'neuro')
        if $self->{tracer};

    # Extract recent user messages to find relevant facts.
    my $messages = $ev->{payload}{messages} // [];
    my $query = _extract_query($messages);
    return unless length $query;

    # Find relevant entities and facts.
    # Extract keywords from query for FTS search.
    my @facts;
    my @keywords = grep { length($_) > 2 } split /\s+/, lc($query);
    my %seen_entities;
    my @all_entities;

    for my $keyword (@keywords) {
        my $entities = $self->{world_model}->search_entities($keyword, limit => $self->{max_facts});
        for my $ent (@$entities) {
            next if $seen_entities{$ent->{id}}++;
            push @all_entities, $ent;
            my $attrs = ref $ent->{attributes} eq 'HASH' ? $ent->{attributes} : {};
            push @facts, sprintf("- %s (%s): %s",
                $ent->{name} // $ent->{id},
                $ent->{type},
                join(', ', map { "$_=$attrs->{$_}" } sort keys %$attrs));
        }
    }

    # Also get recent facts related to matched entities.
    my @top_entities = @all_entities[0..($#all_entities < 4 ? $#all_entities : 4)];
    for my $ent (@top_entities) {
        my $facts = $self->{world_model}->query_facts(entity_id => $ent->{id});
        for my $f (@$facts) {
            push @facts, sprintf("- %s: %s (confidence: %.0f%%)",
                $f->{predicate}, $f->{value} // '', ($f->{confidence} // 1) * 100);
        }
    }

    return unless @facts;

    # Inject as system message.
    my $context = "Known facts from world model:\n" . join("\n", @facts);

    $self->{metrics}->inc('neuro.context_injected') if $self->{metrics};

    if ($self->{tracer} && defined $trace_id) {
        $self->{tracer}->end_span($trace_id);
    }

    return { message => $context };
}

# === PHASE 2: Rules validate LLM output ===

sub _on_message_end {
    my ($self, $ev) = @_;
    return unless $self->{validate} && $self->{world_model};

    my $content = $ev->{payload}{content}{text} // '';
    return unless length $content;

    my $trace_id;
    $trace_id = $self->{tracer}->start_span('neuro.validate_output', topic => 'neuro')
        if $self->{tracer};

    # Run validation rules against the output.
    my @violations = $self->_validate_output($content);

    $self->{metrics}->inc('neuro.validations') if $self->{metrics};

    if (@violations) {
        $self->{metrics}->inc('neuro.violations') if $self->{metrics};

        # Return revision request.
        if ($self->{tracer} && defined $trace_id) {
            $self->{tracer}->end_span($trace_id);
        }
        return {
            role    => 'assistant',
            content => {
                text       => $content,
                tool_calls => [],
                _violations => \@violations,
            },
        };
    }

    if ($self->{tracer} && defined $trace_id) {
        $self->{tracer}->end_span($trace_id);
    }
    return undef;
}

sub _validate_output {
    my ($self, $output) = @_;
    my @violations;

    # Check claims against world model facts.
    # Simple approach: extract noun phrases and check if they contradict known facts.
    my $facts = $self->{world_model}->query_facts();
    for my $fact (@$facts) {
        my $predicate = lc($fact->{predicate} // '');
        my $value = lc($fact->{value} // '');
        next unless length $predicate && length $value;

        # Check for direct contradiction patterns.
        if ($output =~ /(?:is not|isn't|are not|aren't|was not|wasn't)\s+\Q$value\E/i) {
            push @violations, {
                type    => 'contradiction',
                fact    => "$predicate: $value",
                message => "Output contradicts known fact: $predicate is $value",
            };
        }
        if ($output =~ /(?:never|no longer)\s+\Q$value\E/i) {
            push @violations, {
                type    => 'negation',
                fact    => "$predicate: $value",
                message => "Output negates known fact: $predicate is $value",
            };
        }
    }

    return @violations;
}

# === PHASE 3: LLM updates world model ===

sub _on_agent_end {
    my ($self, $ev) = @_;
    return unless $self->{extract} && $self->{world_model};

    my $trace_id;
    $trace_id = $self->{tracer}->start_span('neuro.extract_knowledge', topic => 'neuro')
        if $self->{tracer};

    # Extract entities and facts from the conversation.
    my $session_id = $ev->{payload}{session_id};
    return unless $session_id;

    my $store = $self->{store};
    my $messages = $store->message_path($session_id);
    return unless @$messages;

    # Build conversation text for extraction.
    my $conversation = join("\n", map {
        my $content = ref $_->{content} eq 'HASH'
            ? ($_->{content}{text} // '')
            : ($_->{content} // '');
        sprintf("[%s] %s", $_->{role}, $content);
    } @$messages);

    # Simple extraction: find entity mentions.
    my @entities = _extract_entities($conversation);
    my @facts = _extract_facts($conversation);

    my $added = 0;
    for my $ent (@entities) {
        eval {
            $self->{world_model}->add_entity(
                type       => $ent->{type},
                name       => $ent->{name},
                attributes => $ent->{attrs} // {},
            );
            $added++;
        };
    }

    for my $fact (@facts) {
        eval {
            $self->{world_model}->assert_fact(
                entity_id  => $fact->{entity_id},
                predicate  => $fact->{predicate},
                value      => $fact->{value},
                source     => 'llm_extraction',
                confidence => $fact->{confidence} // 0.7,
            );
            $added++;
        };
    }

    $self->{metrics}->inc('neuro.extracted', $added) if $self->{metrics} && $added;

    if ($self->{tracer} && defined $trace_id) {
        $self->{tracer}->end_span($trace_id);
    }

    return undef;
}

# === HELPERS ===

# Extract the user's query from recent messages.
sub _extract_query {
    my ($messages) = @_;
    # Get the last user message.
    for my $m (reverse @$messages) {
        next unless ($m->{role} // '') eq 'user';
        my $text = ref $m->{content} eq 'HASH'
            ? ($m->{content}{text} // '')
            : ($m->{content} // '');
        return $text if length $text;
    }
    return '';
}

# Simple entity extraction (capitalized words, proper nouns).
sub _extract_entities {
    my ($text) = @_;
    my %seen;
    my @entities;

    # Match capitalized word sequences (simple NER).
    while ($text =~ /\b([A-Z][a-z]+(?:\s+[A-Z][a-z]+)*)\b/g) {
        my $name = $1;
        next if $seen{$name}++;
        next if length($name) < 2;
        # Skip common false positives.
        next if $name =~ /^(The|This|That|When|Where|How|What|Why|Yes|No|And|But|Or|For|Not|You|Can|Will|All|Any|Get|Set|Add|Run|See|Put|Try|Use|Make|Take|Give|Let|One|Two|Six|Ten|New|Old|Big|Far|Low|Our|Its|His|Her|My|Your|Our|Their|Its)$/;

        push @entities, {
            name => $name,
            type => 'concept',
            attrs => {},
        };
    }

    return @entities;
}

# Simple fact extraction (X is Y, X has Y, X does Y patterns).
sub _extract_facts {
    my ($text) = @_;
    my @facts;

    # "X is Y" patterns.
    while ($text =~ /\b(\w+)\s+is\s+(.+?)(?:\.|,|\n|$)/gi) {
        push @facts, {
            predicate => 'is',
            value     => "$1 is $2",
            confidence => 0.6,
        };
    }

    # "X has Y" patterns.
    while ($text =~ /\b(\w+)\s+has\s+(.+?)(?:\.|,|\n|$)/gi) {
        push @facts, {
            predicate => 'has',
            value     => "$1 has $2",
            confidence => 0.6,
        };
    }

    return @facts;
}

1;
