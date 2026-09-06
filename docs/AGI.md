# Neurosymbolic AI in Clam

Status: architecture proposal. This document describes how Clam could evolve
from an LLM harness with symbolic tools into a genuine neurosymbolic system
with explicit world models, bidirectional reasoning, and crystallization.

## 1. What Neurosymbolic AI Is

Gary Marcus champions neurosymbolic AI as the path beyond pure neural networks.
The core insight: LLMs are brilliant pattern recognizers but terrible at
reasoning. Rules engines are brilliant at reasoning but terrible at
understanding natural language. Combining them yields systems that can both
understand and reason.

Neurosymbolic AI requires three things Clam currently lacks:

1. **Explicit world model** — structured representation of entities, relations,
   temporal facts, and causal links that both neural and symbolic components
   read and write.

2. **Bidirectional integration** — LLM generates hypotheses, rules validate
   them, validated facts update the world model, world model constrains
   subsequent LLM generation. This loop doesn't exist in current Clam.

3. **Crystallization** — when the LLM solves a problem, the solution is
   captured as a deterministic rule that runs forever after without LLM
   involvement. The system gets cheaper and faster the more it's used.

## 2. What Clam Already Has

### Symbolic Components

| Component | Location | Capability |
|-----------|----------|------------|
| Rules engine | `lib/Clam/Rules/Engine.pm` | Forward-chaining rule evaluation |
| Datalog | `wits/logic/` | Relational query over facts |
| SAT solver | `wits/logic/` | Constraint satisfaction |
| FSM | `lib/Clam/Rules/FSM.pm` | State machine transitions |
| Behavior trees | `lib/Clam/Rules/BehaviorTree.pm` | Hierarchical task execution |
| Deduction chains | `wits/logic/` | Axiom → rule → conclusion with proof |
| SQLite store | `lib/Clam/Store.pm` | Persistent key-value and event storage |
| Bus/pub-sub | `lib/Clam/Bus.pm` | Minsky's agent communication |

### Neural Components

| Component | Location | Capability |
|-----------|----------|------------|
| LLM providers | `lib/Clam/Provider/` | Ollama, OpenAI, Anthropic, Gemini, Azure |
| Tool calling | `lib/Clam/Tools/` | read, bash, edit, write |
| System prompt | `lib/Clam/Session/SystemPrompt.pm` | Context injection |
| 200+ wits | `wits/` | Domain-specific tools and classifiers |

### The Gap

All these components exist but operate in isolation:

```
LLM generates text → rules run deterministically → output
```

The LLM never learns from rule outcomes. Rules never adapt from LLM insights.
They are parallel tracks, not integrated reasoning.

## 3. The World Model

### 3.1 What a World Model Requires

A world model is not a key-value store. It needs:

- **Entities** — named things with types and attributes
- **Relations** — typed connections between entities
- **Temporal facts** — what was true when, what changed
- **Causal links** — what causes what
- **Beliefs** — what the system thinks is true (with confidence)
- **Counterfactuals** — what would happen if X were different

### 3.2 Schema Design

The world model extends SQLite with a structured schema:

```sql
-- Entities: things the system knows about
CREATE TABLE wm_entities (
    id          TEXT PRIMARY KEY,
    type        TEXT NOT NULL,           -- 'person', 'concept', 'file', 'goal', ...
    name        TEXT,
    attributes  TEXT,                    -- JSON blob
    created_at  INTEGER,
    updated_at  INTEGER
);

-- Relations: typed connections between entities
CREATE TABLE wm_relations (
    id          INTEGER PRIMARY KEY,
    source_id   TEXT NOT NULL REFERENCES wm_entities(id),
    target_id   TEXT NOT NULL REFERENCES wm_entities(id),
    type        TEXT NOT NULL,           -- 'depends_on', 'causes', 'part_of', ...
    attributes  TEXT,                    -- JSON blob
    confidence  REAL DEFAULT 1.0,        -- 0.0 to 1.0
    created_at  INTEGER,
    valid_until INTEGER                  -- NULL = still valid
);

-- Temporal facts: what was true when
CREATE TABLE wm_facts (
    id          INTEGER PRIMARY KEY,
    entity_id   TEXT REFERENCES wm_entities(id),
    predicate   TEXT NOT NULL,           -- 'is_above', 'has_value', ...
    value       TEXT,                    -- JSON value
    confidence  REAL DEFAULT 1.0,
    source      TEXT,                    -- 'llm', 'rule', 'observation', 'user'
    valid_from  INTEGER NOT NULL,
    valid_until INTEGER                  -- NULL = still valid
);

-- Causal links: what causes what
CREATE TABLE wm_causes (
    id              INTEGER PRIMARY KEY,
    cause_entity    TEXT REFERENCES wm_entities(id),
    effect_entity   TEXT REFERENCES wm_entities(id),
    mechanism       TEXT,                -- description of causal pathway
    confidence      REAL DEFAULT 1.0,
    evidence        TEXT                 -- JSON array of supporting facts
);

-- Beliefs: what the system thinks (with provenance)
CREATE TABLE wm_beliefs (
    id          INTEGER PRIMARY KEY,
    statement   TEXT NOT NULL,           -- natural language claim
    confidence  REAL DEFAULT 0.5,
    source      TEXT,                    -- 'llm', 'rule', 'inference'
    evidence    TEXT,                    -- JSON array of fact IDs
    created_at  INTEGER,
    superseded_by INTEGER REFERENCES wm_beliefs(id)
);
```

### 3.3 World Model Operations

```perl
package Clam::WorldModel;

# Entity operations
sub add_entity    { ... }   # create or update entity
sub get_entity    { ... }   # retrieve entity with attributes
sub query_entities { ... }  # find entities by type/attribute

# Relation operations
sub add_relation  { ... }   # create relation between entities
sub get_relations { ... }   # find relations by type/source/target
sub infer_relations { ... } # derive new relations from existing ones

# Fact operations
sub assert_fact   { ... }   # add temporal fact
sub query_facts   { ... }   # find facts by entity/predicate/time
sub retract_fact  { ... }   # mark fact as no longer valid

# Causal operations
sub add_cause     { ... }   # record causal link
sub trace_causes  { ... }   # find all causes of an effect
sub predict_effects { ... } # find all effects of a cause

# Belief operations
sub believe       { ... }   # add belief with confidence
sub query_beliefs { ... }   # find beliefs by statement/confidence
sub update_belief { ... }   # supersede old belief with new evidence
```

### 3.4 Integration with Existing Store

The world model sits alongside the existing `Clam::Store`:

```
lib/Clam/
  Store.pm            # existing: sessions, messages, kv, events
  WorldModel.pm       # new: entities, relations, facts, causes, beliefs
```

`Store.pm` handles session state. `WorldModel.pm` handles world knowledge.
They share the same SQLite database but different tables.

## 4. Bidirectional Integration

### 4.1 The Loop

The current flow is unidirectional:

```
User → LLM → Tools → Rules → Output
```

The neurosymbolic flow is circular:

```
User → LLM generates hypothesis → Rules validate → World Model updates → LLM constrained by world model → Output
```

### 4.2 Implementation

#### Phase 1: LLM reads world model

When the LLM generates a response, inject relevant world model facts into
the system prompt:

```perl
sub build_context {
    my ($self) = @_;
    my $chain = Clam::Session::Messages::chain($self->{store}, $self->{id});

    # NEW: inject world model facts relevant to current query
    my $world_context = $self->{world_model}->relevant_facts($chain);
    push @$chain, { role => 'system', content => $world_context };

    return Clam::Session::Messages::to_provider_list($chain);
}
```

This is the simplest integration — the LLM sees what the world model knows.

#### Phase 2: Rules validate LLM output

After the LLM generates output but before emitting it, run validation rules:

```perl
sub validate_output {
    my ($self, $output) = @_;

    # Run validation rules against LLM output
    my @violations = $self->{rules}->validate($output);

    if (@violations) {
        # World model detected contradiction — ask LLM to revise
        my $revised = $self->{provider}->post_json('/chat/completions', {
            model    => $self->{provider}{model},
            messages => [
                @{ $self->build_context },
                { role => 'assistant', content => $output },
                { role => 'system', content =>
                    "Your response contradicts known facts: "
                    . join("\n", @violations)
                    . "\nPlease revise." },
            ],
        });
        return $revised->{choices}[0]{message}{content};
    }

    return $output;
}
```

#### Phase 3: LLM updates world model

After successful interaction, extract new knowledge from the conversation:

```perl
sub extract_world_facts {
    my ($self, $conversation) = @_;

    # Ask LLM to extract entities, relations, and facts
    my $extraction = $self->{provider}->post_json('/chat/completions', {
        model    => $self->{provider}{model},
        messages => [
            { role => 'system', content =>
                "Extract entities, relations, and facts from this conversation.
                 Return JSON: { entities: [...], relations: [...], facts: [...] }" },
            { role => 'user', content => $conversation },
        ],
    });

    # Update world model with extracted knowledge
    my $data = decode_json($extraction->{choices}[0]{message}{content});
    $self->{world_model}->update_from_extraction($data);
}
```

### 4.3 The Complete Pipeline

```
┌─────────────────────────────────────────────────────────────┐
│                        User Input                           │
└─────────────────────┬───────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────┐
│              World Model Context Injection                   │
│  Query relevant facts, beliefs, and relations               │
└─────────────────────┬───────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────┐
│                    LLM Generation                            │
│  Generate response constrained by world model context       │
└─────────────────────┬───────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────┐
│                  Rule Validation                             │
│  Check output against world model facts and beliefs         │
└─────────────────────┬───────────────────────────────────────┘
                      │
              ┌───────┴───────┐
              │               │
              ▼               ▼
        ┌──────────┐    ┌──────────┐
        │  Valid   │    │ Invalid  │
        └────┬─────┘    └────┬─────┘
             │               │
             │               ▼
             │        ┌──────────────┐
             │        │ LLM Revision │
             │        │ (with facts) │
             │        └──────┬───────┘
             │               │
             ▼               ▼
┌─────────────────────────────────────────────────────────────┐
│              World Model Update                              │
│  Extract new entities, relations, facts from conversation   │
└─────────────────────┬───────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────┐
│                   Output to User                             │
└─────────────────────────────────────────────────────────────┘
```

## 5. Crystallization

### 5.1 What Crystallization Means

When the LLM solves a problem, the solution should be captured as a
deterministic rule. The system gets cheaper and faster the more it's used.

Example:
- LLM is asked "what's the capital of France?"
- LLM responds "Paris"
- System creates rule: `capital_of(france) = paris`
- Next time, rule fires instantly without LLM involvement

### 5.2 Crystallization Pipeline

```perl
sub crystallize {
    my ($self, $interaction) = @_;

    # 1. LLM identifies reusable patterns
    my $patterns = $self->{provider}->post_json('/chat/completions', {
        model    => $self->{provider}{model},
        messages => [
            { role => 'system', content =>
                "Identify reusable rules from this interaction.
                 Return JSON: { rules: [{ name, condition, action, confidence }] }" },
            { role => 'user', content => $interaction },
        ],
    });

    # 2. Validate proposed rules against world model
    my $data = decode_json($patterns->{choices}[0]{message}{content});
    my @validated;
    for my $rule (@{ $data->{rules} }) {
        if ($self->{world_model}->supports_rule($rule)) {
            push @validated, $rule;
        }
    }

    # 3. Register validated rules
    for my $rule (@validated) {
        $self->{rules}->add_rule(
            name       => $rule->{name},
            condition  => $rule->{condition},
            action     => $rule->{action},
            confidence => $rule->{confidence},
            source     => 'crystallized',
        );
    }

    return scalar @validated;
}
```

### 5.3 Crystallization Triggers

Crystallization should happen when:

- The LLM provides a definitive answer to a factual question
- A deduction chain reaches a conclusion
- The user confirms a correction
- A pattern repeats across multiple interactions

### 5.4 Crystallized Rule Storage

Crystallized rules live in the rules engine alongside hand-written rules:

```sql
CREATE TABLE crystallized_rules (
    id          INTEGER PRIMARY KEY,
    name        TEXT NOT NULL,
    condition   TEXT NOT NULL,        -- Perl expression or Datalog
    action      TEXT NOT NULL,        -- Perl code or fact assertion
    confidence  REAL DEFAULT 1.0,
    source      TEXT,                 -- 'crystallized', 'llm', 'rule'
    created_at  INTEGER,
    last_used   INTEGER,
    use_count   INTEGER DEFAULT 0
);
```

## 6. Philosophical Constraint Schemas

### 6.1 From Taxonomy to Rules

The minsky.txt taxonomy of 200+ agent types across philosophical frameworks
can be distilled into constraint schemas — rules that the LLM's output must
satisfy before emission.

These are not agent types. They are validation rules:

```perl
# Stoic constraint: separate controllable from uncontrollable
sub stoic_control_check {
    my ($output, $world_model) = @_;
    my @violations;

    # Check if output promises outcomes outside system control
    if ($output =~ /\b(?:will guarantee|promise to ensure|definitely will)\b/i) {
        my $controllable = $world_model->query_beliefs(
            statement => 'system_can_control',
            confidence => 0.8,
        );
        if (!$controllable) {
            push @violations, "Stoic: promises outcomes outside system control";
        }
    }

    return @violations;
}

# Confucian constraint: relational appropriateness
sub confucian_li_check {
    my ($output, $context) = @_;
    my @violations;

    # Check if output violates social context
    if ($context->{user_role} eq 'elder' && $output =~ /\byou should\b/i) {
        push @violations, "Confucian: directive language toward elder";
    }

    return @violations;
}

# Care ethics constraint: attentiveness
sub care_ethics_check {
    my ($output, $conversation) = @_;
    my @violations;

    # Check if output ignores emotional content
    if ($conversation =~ /\b(?:frustrated|angry|sad|upset)\b/i
        && $output !~ /\b(?:understand|sorry|difficult|hard)\b/i) {
        push @violations, "Care ethics: ignores emotional content";
    }

    return @violations;
}
```

### 6.2 Constraint Schema Registry

```perl
package Clam::Constraints;

my @SCHEMAS = (
    { name => 'stoic_control',      fn => \&stoic_control_check },
    { name => 'confucian_li',       fn => \&confucian_li_check },
    { name => 'care_ethics',        fn => \&care_ethics_check },
    { name => 'marx_alienation',    fn => \&marx_alienation_check },
    { name => 'jung_shadow',        fn => \&jung_shadow_check },
    { name => 'freud_superego',     fn => \&freud_superego_check },
    # ... more schemas from minsky.txt taxonomy
);

sub validate {
    my ($self, $output, $context) = @_;
    my @all_violations;

    for my $schema (@SCHEMAS) {
        my @v = $schema->{fn}->($output, $context);
        push @all_violations, map { "[$schema->{name}] $_" } @v;
    }

    return @all_violations;
}
```

## 7. Implementation Roadmap

### Phase 1: World Model Foundation (Weeks 1-4)

1. Design and implement `Clam::WorldModel` with SQLite schema
2. Add entity/relation/fact CRUD operations
3. Integrate with `Clam::Store` (same database, separate tables)
4. Write tests for world model operations
5. Add basic world model queries to session context

**Deliverable:** `lib/Clam/WorldModel.pm` with full test suite

### Phase 2: Bidirectional Context (Weeks 5-8)

1. Implement world model context injection into system prompt
2. Add rule validation layer after LLM output
3. Implement LLM revision loop when rules flag violations
4. Add world fact extraction from successful conversations
5. Write integration tests for the full loop

**Deliverable:** Working bidirectional LLM ↔ rules integration

### Phase 3: Crystallization (Weeks 9-12)

1. Implement pattern extraction from LLM interactions
2. Add rule validation against world model before crystallization
3. Implement crystallized rule storage and execution
4. Add crystallization triggers (factual answers, confirmed corrections)
5. Write tests for crystallized rule execution

**Deliverable:** System that gets faster with use

### Phase 4: Constraint Schemas (Weeks 13-16)

1. Implement constraint schema registry
2. Port philosophical constraints from minsky.txt taxonomy
3. Add constraint validation to output pipeline
4. Implement constraint-aware LLM revision
5. Write tests for each constraint schema

**Deliverable:** Philosophically grounded output validation

### Phase 5: Advanced Reasoning (Weeks 17-20)

1. Implement causal reasoning over world model
2. Add counterfactual queries ("what if X were different?")
3. Implement belief revision with confidence propagation
4. Add temporal reasoning (what was true when)
5. Write tests for advanced reasoning operations

**Deliverable:** World model with causal and temporal reasoning

## 8. Success Criteria

The system is neurosymbolic when:

1. **World model exists** — entities, relations, facts, causes, beliefs
   are stored and queryable
2. **Bidirectional flow works** — LLM reads world model, rules validate
   LLM output, conversation updates world model
3. **Crystallization happens** — LLM solutions become deterministic rules
4. **Constraints are enforced** — philosophical schemas validate output
5. **The system improves** — crystallized rules reduce LLM calls over time
6. **Reasoning is explainable** — every conclusion has a traceable path
   through world model facts and rules

## 9. Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| World model becomes stale | Contradictions between model and reality | Temporal facts with expiry, regular reconciliation |
| Crystallized rules conflict | Inconsistent behavior | Rule conflict detection, confidence-based priority |
| LLM hallucinates world facts | Corrupted world model | Confidence thresholds, human-in-the-loop for high-stakes facts |
| Constraint schemas too rigid | Refuses valid outputs | Configurable constraint strength, learning from false positives |
| Performance overhead | Slow responses | Async world model updates, cached context, selective validation |

## 10. References

- Marcus, G. (2020). *The Next Decade in AI: Four Steps Towards Robust Artificial Intelligence*
- Minsky, M. (1986). *The Society of Mind*
- Garcez, A. d'A., et al. (2019). *Neural-Symbolic Computing: An Effective Methodology for Principled Integration of Machine Learning and Reasoning*
- Hamilton, W. L. (2020). *Logical Entailment and Neural-Symbolic AI*
- Lake, B. M., et al. (2017). *Building machines that learn and think like people*
- Clark, A. (2013). *Whatever Next? Predictive Brains, Situated Agents, and the Future of Cognitive Science*
