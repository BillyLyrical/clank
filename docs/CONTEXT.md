# Context Engineering for Clank

Status: design document. Practical architecture for teaching LLMs what's
available as Clank scales to hundreds of wits.

---

## 1. The Problem

Clank ships 88 wits across 6 decks today. The vision is hundreds. At that
scale, the naive approach — dump every tool schema into the system prompt —
fails catastrophically:

- **Token cost**: 500 tools x ~100 tokens each = 50k tokens. That's a
  third of a 128k context window, burned before the user speaks.
- **Selection degradation**: LLMs struggle to pick the right tool from
  long lists. Performance drops measurably past ~50 tools.
- **Context pollution**: Tool schemas crowd out conversation history,
  retrieved knowledge, and reasoning space.

This is the **Context Engineering** problem: the discipline of assembling
the right information, in the right format, at the right time, so the
LLM can actually do its job.

The industry consensus (Anthropic, OpenAI, LangGraph, 12-Factor Agents)
is clear: **most agent failures are context failures, not model failures.**
The quality of what you put in the window determines what comes out.

---

## 2. What the Industry Has Learned

### 2.1 Context Is a System, Not a String

The prompt is the *output* of a pipeline, not a hand-written template.
Before each LLM call, a system assembles context from multiple sources:
instructions, conversation history, retrieved documents, tool definitions,
output schemas. Each source is pulled dynamically per task.

### 2.2 Tool Selection via Retrieval

When an agent has many tools, embeddings-based retrieval fetches only
semantically relevant tool definitions. Research shows 3x improvement
in tool selection accuracy vs. listing all tools. The key: tool
descriptions are indexed like documents, and the current prompt is the
query.

### 2.3 Context Compression

Long conversations degrade performance through poisoning (hallucination
in context), distraction (context overwhelms reasoning), confusion
(superfluous data), and clash (contradictions). Solutions:
- Summarization (recursive, hierarchical)
- Pruning (drop resolved errors, old turns)
- Post-tool-call summarization (compress heavy outputs before re-entry)

### 2.4 Memory Layers

Three memory types serve different purposes:
- **Episodic**: few-shot examples of past behavior (what worked before)
- **Procedural**: instructions and rules (how to do things)
- **Semantic**: factual knowledge about the world (what is true)

Each is selected differently. Fixed files (CLAUDE.md, .cursorrules)
serve procedural memory. Embeddings serve semantic memory. Conversation
history serves episodic memory.

### 2.5 Code-as-Action

Instead of tool-call APIs returning JSON, have the LLM emit executable
code in a sandboxed environment. This isolates heavy intermediate data
and gives the developer full control over what re-enters the context
window. (HuggingFace CodeAgent approach.)

---

## 3. What Clank Already Has

Clank's architecture maps directly to these patterns:

| Industry Pattern | Clank Equivalent | Status |
|-----------------|-----------------|--------|
| Context assembly pipeline | Bus + SystemPrompt | Exists, needs enhancement |
| Tool selection via retrieval | ToolSelector (RATS) | Exists, keyword-based |
| Context compression | Compaction (Pi semantics) | Exists, LLM-based |
| World model (semantic memory) | WorldModel + NeuroIntegration | Exists, bidirectional |
| Deterministic rules | Logic + Rules + FSM + BT | Exists, full suite |
| Self-describing tools | `# CLANK-WIT:` comments | Exists, grep-based |
| Crystallization (learn from use) | Crystallizer | Exists, captures patterns |
| Event-sourced state | Store + Bus + EventSourcing | Exists, journaled |
| SQLite retrieval | Store (FTS5, RAG) | Exists, fast |

Clank is not starting from zero. The infrastructure is there. What's
missing is the *orchestration layer* that ties these pieces into a
coherent context engineering system.

### 3.1 Current Mechanisms and Their Limitations

| Mechanism | What it does | Limitation |
|-----------|-------------|------------|
| `# CLANK-WIT:` comments | Grep-able metadata, source of truth | Filesystem-only; LLM can't grep at runtime |
| `hint` field | Dense keywords for tool selection | Per-tool, no deck-level awareness |
| ToolSelector (RATS) | Scores tools by keyword overlap | Tool-level only; no capability overview |
| System prompt injection | Tool schemas injected into context | Bloats with load count; no hierarchy |

The gap: the LLM can't discover what's available at runtime. The
manifest bridges this by reflecting what's *actually loaded*, not what
*could be loaded*.

### 3.2 Self-Describing Wits

The LLM can't grep `@INC` at runtime. The manifest makes wits
self-describing to the LLM. For deeper introspection, a `/wits inspect
<name>` command returns the full wit metadata: tools, commands, bus
hooks, about, usage, hint.

The LLM's mental model becomes:
1. Read manifest → see what decks exist
2. If task matches a deck → request deeper context
3. Deeper context includes full tool schemas for that deck
4. Call tools, inspect results, iterate

---

## 4. The Architecture: Three Context Pipelines

The solution is three separate pipelines, each responsible for a
different aspect of context. They compose into a single system prompt
before each LLM call.

### 4.1 Pipeline 1: Capability Context (What Can I Do?)

**Problem**: The LLM needs to know what tools exist without seeing all
of them. It cannot use what it cannot name.

**Solution**: A tiered capability manifest, generated from SQLite, not
filesystem scan. Four tiers, each adding context at increasing cost:

```
Tier 0: Core tools (always loaded, ~200 tokens)
  read, bash, edit, write — the Pi-parity basics

Tier 1: Capability manifest (~500 tokens, always present)
  Deck names, hint keywords, one-line descriptions
  Generated from PluginManager::manifest() at startup

Tier 2: Relevant tool schemas (on-demand, ~2000 tokens)
  Selected by ToolSelector based on current prompt
  Scores: keyword overlap + conversation context + recency

Tier 3: Full deck documentation (on-demand, ~5000 tokens)
  Only when LLM explicitly requests a deck
  Triggered by "I need X" or "%deck-name" sigil
```

**Manifest format** (injected into system prompt):

```
CAPABILITIES (88 wits, 6 decks):
  logic   datalog, rules-dsl, fsm, behavior-tree, sat-solver [reasoning]
  git     status, log, diff, blame, commit, guard [source-control]
  fs      read, write, edit, glob, mkdir [filesystem]
  db      connect, query, execute, schema [database]
  perl    syntax, critic, tidy, pod, test [perl-dev]
  psh     eval, vars, help [repl]
  critic  code-review, quality-score [analysis]
  search  local, web, embedding [retrieval]
  neuro   world-model, crystallizer, constraints [neurosymbolic]
```

**Token cost**: ~500 for 88 wits. Negligible.

**Generation**: `PluginManager` already tracks loaded wits. Add a
`manifest()` method that returns the formatted string. `SystemPrompt`
calls it and injects the result. No filesystem scan needed — the DB
is the runtime view.

**Implementation**: `SystemPrompt` builds tier 0+1 always. Tier 2 is
injected by a `context.assemble` bus hook that runs before each LLM
call. Tier 3 is loaded on explicit request.

**Key insight**: The manifest is not a static list. It's a SQLite query
that reflects what's *actually loaded* and *recently used*. If the LLM
just used git tools, git stays in tier 2. If it hasn't touched db tools
in 10 turns, they drop back to tier 1 only.

### 4.2 Pipeline 2: Knowledge Context (What Do I Know?)

**Problem**: The LLM needs relevant facts from the world model, past
conversations, and the current codebase — without being overwhelmed.

**Solution**: Retrieval-augmented context assembly, with SQLite FTS5
as the retrieval engine.

```
Sources (in priority order):
  1. Current task context (git status, open files, errors)
  2. World model facts relevant to the prompt
  3. Past conversation summaries (compaction entries)
  4. Crystallized rules (deterministic shortcuts)
  5. Project memory (MEMORY.md, AGENTS.md)
  6. User preferences (global MEMORY.md)
```

**Implementation**: A `KnowledgeAssembler` module queries each source,
scores relevance against the current prompt, and returns the top-N
facts. The Bus publishes `context.knowledge_request` with the prompt;
subscribers (WorldModel, Compaction, Crystallizer, Store) each respond
with relevant snippets.

**Key insight**: SQLite FTS5 is faster and more predictable than
embeddings for structured retrieval. Use it for everything that lives
in the Store. Reserve embeddings for unstructured text (code comments,
documentation).

### 4.3 Pipeline 3: Behavioral Context (How Should I Act?)

**Problem**: The LLM needs to know the rules, constraints, and
preferences that apply to this task — without a 10k-token system prompt.

**Solution**: Rule-based context injection, powered by the Logic engine.

```
Sources:
  1. Core rules (always): security, safety, code style
  2. Deck-specific rules: loaded with the deck
  3. Session rules: accumulated during conversation
  4. Crystallized rules: learned from past interactions
  5. User preferences: from global/project memory
```

**Implementation**: The Rules DSL evaluates conditions against the
current context (prompt keywords, loaded wits, user history) and
selects which rules to inject. This is *deterministic* — no LLM call
needed to decide what rules apply.

**Key insight**: Rules are cheap. A rule like "when editing Perl files,
enforce strict/warnings" costs ~50 tokens to inject. A Datalog query
that checks "is the user editing a file? is it Perl? has the user
opted out of strict checking?" is microseconds. This is the
computational escalation principle: try the cheapest correct tool first.

---

## 5. The Context Assembly Sequence

Before each LLM call, the context is assembled in this order:

```
1. CAPABILITY CONTEXT (Pipeline 1)
   - Load tier 0 (core tools)
   - Load tier 1 (manifest)
   - Load tier 2 (relevant tools from ToolSelector)
   - Total: ~2700 tokens

2. BEHAVIORAL CONTEXT (Pipeline 3)
   - Evaluate rules against current context
   - Select applicable rules
   - Format as concise instructions
   - Total: ~500-2000 tokens

3. KNOWLEDGE CONTEXT (Pipeline 2)
   - Query world model for relevant facts
   - Query compaction for past summaries
   - Query crystallizer for deterministic shortcuts
   - Query project memory
   - Total: ~1000-3000 tokens

4. CONVERSATION HISTORY
   - Recent messages (kept_recent from Compaction)
   - Current user prompt
   - Total: variable

5. FINAL ASSEMBLY
   - System prompt = core instructions + capability + behavioral + knowledge
   - Messages = history + user prompt
   - Tools = tier 0 + tier 2 schemas
   - Total system prompt: ~5000-8000 tokens (vs. 50k naive)
```

---

## 6. How Clank's Existing Modules Participate

### 6.1 ToolSelector (Enhanced)

Current: keyword-based TF scoring.
Enhanced: add conversation context as additional signal.

```perl
# Before (keyword-only):
my $relevant = Clank::ToolSelector->select(
    tools => \@all_tools,
    prompt => $user_prompt,
    max => 30,
);

# After (context-aware):
my $relevant = Clank::ToolSelector->select(
    tools    => \@all_tools,
    prompt   => $user_prompt,
    context  => {
        recent_tools => \@recently_used,     # recency bias
        loaded_wits  => \@loaded_wits,       # deck affinity
        file_types   => \@open_files,        # domain signals
        error_msg    => $last_error,         # error recovery hints
    },
    max => 30,
);
```

The `context` hash adds secondary signals that boost tools matching
the current working state, not just the prompt text.

### 6.2 Compaction (as Context Source)

Current: summarizes old conversation into structured summary.
Enhancement: compaction summaries become a retrieval source for
Knowledge Context. When assembling context for a new prompt, query
past compaction entries for relevant summaries.

```perl
# Query compaction for relevant past context
my @summaries = $store->query_compaction(
    session_id => $sid,
    prompt     => $user_prompt,
    limit      => 3,
);
```

### 6.3 WorldModel (as Context Source)

Current: stores entities, relations, facts, beliefs.
Enhancement: the `context.knowledge_request` bus event triggers
WorldModel to query relevant facts and inject them.

```perl
# On context.knowledge_request
$bus->subscribe('context.knowledge_request', sub {
    my ($ev) = @_;
    my $prompt = $ev->{payload}{prompt};
    my @facts = $world_model->query_relevant(
        prompt => $prompt,
        limit  => 20,
    );
    # Publish back as context.knowledge_response
    $bus->publish('context.knowledge_response', {
        request_id => $ev->{payload}{request_id},
        facts      => \@facts,
    });
});
```

### 6.4 Crystallizer (as Context Source)

Current: captures LLM solutions as deterministic rules.
Enhancement: crystallized rules are injected into Behavioral Context
when the current task matches their trigger conditions.

```perl
# Query crystallized rules for current context
my @rules = $crystallizer->matching_rules(
    prompt    => $user_prompt,
    file_type => $current_file_type,
    limit     => 10,
);
# Each rule is ~50 tokens: "When editing Perl, always add strict/warnings"
```

### 6.5 NeuroIntegration (as Context Orchestrator)

Current: three phases (inject, validate, extract).
Enhancement: Phase 1 (inject) becomes the primary context assembly
orchestrator. It subscribes to `context.assemble` and coordinates
all three pipelines.

### 6.6 Bus (as Context Spine)

Current: pub/sub over SQLite, journaled events.
Enhancement: bus topics for context assembly:
- `context.assemble` — trigger full context assembly
- `context.capability_request` — request tool schemas
- `context.knowledge_request` — request relevant facts
- `context.rule_request` — request applicable rules
- `context.assembled` — final context ready

---

## 7. The SQLite Advantage

Clank's choice of SQLite as the backbone is a decisive advantage here.
Every context source is a SQLite query:

| Context Source | SQLite Table | Query Type |
|---------------|-------------|------------|
| Tool metadata | `wits` + `tools` | SELECT with FTS5 match |
| World model facts | `wm_facts` + `wm_entities` | FTS5 + temporal filter |
| Compaction summaries | `messages` WHERE role='compaction' | FTS5 + recency |
| Crystallized rules | `crystallized_rules` | FTS5 + confidence filter |
| Conversation history | `messages` | Tree walk + token estimate |
| Project memory | `memory` | FTS5 + scope filter |

No external services. No embedding servers. No vector databases.
SQLite FTS5 handles retrieval at microsecond latency. The Bus
coordinates assembly. Perl processes results.

---

## 8. Implementation Plan

### Phase 1: Capability Manifest (immediate, ~2 hours)

**What**: Generate a deck-level capability manifest from PluginManager.

**Files to change**:
- `lib/Clank/PluginManager.pm` — add `manifest()` method
- `lib/Clank/Session/SystemPrompt.pm` — inject manifest

**Manifest format**:
```
CAPABILITIES (88 wits, 6 decks):
  logic   datalog, rules-dsl, fsm, behavior-tree, sat-solver [reasoning]
  git     status, log, diff, blame, commit, guard [source-control]
  fs      read, write, edit, glob, mkdir [filesystem]
  db      connect, query, execute, schema [database]
  perl    syntax, critic, tidy, pod, test [perl-dev]
  psh     eval, vars, help [repl]
  critic  code-review, quality-score [analysis]
  search  local, web, embedding [retrieval]
  neuro   world-model, crystallizer, constraints [neurosymbolic]
```

**Token cost**: ~500. Always present. No external dependencies.

### Phase 2: Enhanced ToolSelector (1 day)

**What**: Add context signals to tool scoring.

**Files to change**:
- `lib/Clank/ToolSelector.pm` — accept `context` hash, weight signals
- `lib/Clank/Loop.pm` — pass context to ToolSelector

**Signals to add**:
- `recent_tools`: tools used in last 3 turns get a boost
- `loaded_wits`: tools from currently loaded wits get a boost
- `file_types`: tools matching open file types get a boost
- `error_msg`: tools that handle the last error get a boost

### Phase 3: Context Assembly Bus (2 days)

**What**: Wire the three-pipeline assembly via bus events.

**Files to change**:
- `lib/Clank/Session/SystemPrompt.pm` — publish `context.assemble`
- `lib/Clank/NeuroIntegration.pm` — subscribe, coordinate pipelines
- `lib/Clank/WorldModel.pm` — subscribe to `context.knowledge_request`
- `lib/Clank/Crystallizer.pm` — subscribe to `context.knowledge_request`

**Bus topics**:
```
context.assemble          → triggers full assembly
context.capability_request → ToolSelector responds
context.knowledge_request → WorldModel + Crystallizer respond
context.rule_request      → Rules engine responds
context.assembled         → final context ready
```

### Phase 4: Context Compression (2 days)

**What**: Post-tool-call summarization + context-aware pruning.

**Files to change**:
- `lib/Clank/Loop.pm` — summarize tool results > 1000 tokens
- `lib/Clank/Session/Compaction.pm` — add relevance-based pruning
- `lib/Clank/Session/Messages.pm` — add `estimate_tokens()` refinement

**Strategy**:
- Tool results > 1000 tokens: summarize before re-entry
- Conversation turns older than 20 turns: prune if not referenced
- Compaction summaries: keep all (they're already compressed)

### Phase 5: Deterministic Context Rules (1 day)

**What**: Use the Rules DSL to select context injection rules.

**Files to change**:
- `lib/Clank/Rules/DSL.pm` — add context rule patterns
- `lib/Clank/Session/SystemPrompt.pm` — evaluate rules for context

**Rule examples**:
```perl
# When editing Perl, inject strict/warnings reminder
rule inject_perl_style {
    when { $prompt =~ /edit|write|create/ && $file_type eq 'perl' }
    inject { "Always use strict and warnings in Perl code." }
}

# When user asks about database, inject db wit context
rule inject_db_context {
    when { $prompt =~ /database|query|sql|table/ }
    inject { $capability_manifest->{db} }
}
```

---

## 9. Cost Analysis

| Approach | Tokens (system prompt) | Cost per call (GPT-4o) | Latency |
|----------|----------------------|------------------------|---------|
| Naive (all tools) | ~50,000 | ~$0.15 | High |
| Tier 1 only (manifest) | ~5,000 | ~$0.015 | Low |
| Tier 1+2 (manifest + relevant) | ~7,000 | ~$0.021 | Low |
| Full assembly (all pipelines) | ~10,000 | ~$0.03 | Medium |

The full assembly approach costs 80% less than naive, with better
tool selection accuracy. The Tier 1+2 approach costs 86% less and
covers 90% of use cases.

---

## 10. Open Questions

1. **Embedding vs. FTS5**: Should we add embeddings for unstructured
   text (code comments, docs)? FTS5 handles structured data well.
   Answer: add embeddings as an optional wit, not core. FTS5 is the
   default.

2. **Context budget**: How many tokens should each pipeline consume?
   Suggested: capability (2700), behavioral (1500), knowledge (2000),
   history (variable). Total budget: 10k for system prompt.

3. **Cache invalidation**: When a wit is loaded/unloaded, the
   capability manifest changes. Should we re-assemble context
   immediately? Answer: yes, publish `context.invalidate` on
   wit load/unload.

4. **Cross-session memory**: World model facts persist, but
   conversation history is per-session. Should context assembly
   pull from past sessions? Answer: only through compaction
   summaries and crystallized rules, not raw history.

5. **LLM-generated context rules**: Can the LLM propose new context
   injection rules? Answer: yes, via Crystallizer. If the LLM
   repeatedly asks for a specific context, crystallize it as a rule.
