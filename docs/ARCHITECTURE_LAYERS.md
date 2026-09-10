# Clank Architecture: Three-Layer Separation

How Clank separates concerns at scale. ECC learned this from maintaining
286 skills, 68 agents, and 94 hook processes — separation prevents
the system from becoming unmaintainable.

---

## The Three Layers

```
┌─────────────────────────────────────────────────┐
│  AGENTS — who does it                           │
│  Named profiles with prompt + tool allowlist    │
│  Example: reviewer, planner, debugger           │
│  Location: agents/*.toml + agents/*.md          │
├─────────────────────────────────────────────────┤
│  SKILLS (Wits) — what workflow                  │
│  Tool definitions + bus subscriptions           │
│  Example: TddWorkflow, GateGuard, Council       │
│  Location: wits/<deck>/lib/Clank/Wits/          │
├─────────────────────────────────────────────────┤
│  HOOKS — what triggers automatically            │
│  Bus events that fire deterministically         │
│  Example: pre_tool_use, post_tool_use,          │
│           observation, context_knowledge_request │
│  Location: bus event subscriptions in wits      │
└─────────────────────────────────────────────────┘
```

## Layer Responsibilities

### Agents (Who)

Agents answer: **who should execute this task?**

- Named profiles (TOML + Markdown)
- Tool allowlists (constrain what the agent can do)
- Model selection (cheap for triage, expensive for analysis)
- Prompt templates (domain-specific instructions)

Agents don't contain tool definitions or bus subscriptions.
They reference wits that provide capabilities.

### Skills / Wits (What)

Wits answer: **what capabilities are available?**

- Tool registrations (`$api->register_tool`)
- REPL commands (`$api->register_command`)
- Bus subscriptions (`$api->on`)
- Domain-specific logic

Wits don't decide who runs. They provide capabilities
that agents and the core loop select from.

### Hooks (What Triggers)

Hooks answer: **when does something happen automatically?**

- Bus events fire deterministically (100% reliable)
- Subscribers react to events without LLM judgment
- Examples: GateGuard blocks edits on `pre_tool_use`,
  Crystallizer captures patterns on `agent_end`,
  Instincts update on `observation`

Hooks are the glue between wits and the execution lifecycle.

## Current Clank Mapping

| Layer | What | Example |
|-------|------|---------|
| Agent | Named profile | `agents/reviewer.toml` (planned) |
| Wit | Tool + bus subscription | `GateGuard.pm` (blocks edits) |
| Wit | Tool + command | `Perl::Test.pm` (runs tests) |
| Wit | Bus subscription only | `Crystallizer.pm` (captures patterns) |
| Hook | `pre_tool_use` event | GateGuard blocks first edit |
| Hook | `observation` event | Crystallizer updates instincts |
| Hook | `context_knowledge_request` | WorldModel + Crystallizer provide facts |

## Scaling Threshold

At ~200 wits, the separation matters for navigation:
- "I need a tool for X" → search wits by hint
- "I need someone to do Y" → search agents by description
- "I need Z to happen automatically" → search hooks by event topic

Below ~100 wits, the current flat wit structure works fine.
The three-layer documentation prepares for that scaling point.

## Anti-Patterns

- **Agents with tool definitions**: agents reference wits, not define tools
- **Wits with routing logic**: routing is a core/agent concern
- **Hooks that require LLM calls**: hooks are deterministic; use wits for LLM-driven behavior
- **Wits that spawn subagents**: that's an agent concern
