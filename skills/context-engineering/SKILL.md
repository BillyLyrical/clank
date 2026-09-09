---
name: context-engineering
description: How Clank assembles context for the LLM. Use when modifying context assembly, tool selection, or system prompt building.
---

# Context Engineering

## The Five Pipelines

Before each LLM call, Loop.pm assembles context in this order:

1. **Capability Context** — `PluginManager::manifest()` → system prompt (~500 tokens)
2. **Behavioral Context** — `ContextRules` → deterministic DSL injections (~200-800 tokens)
3. **Knowledge Context** — bus `context.knowledge_request` → WorldModel + Crystallizer (~200-1000 tokens)
4. **Context Compression** — post-tool-call summarization + pruning
5. **Conversation History** — recent messages + current user prompt

Total: ~5-8k tokens instead of 50k naive.

## Key Modules

| Module | Pipeline | Purpose |
|--------|----------|---------|
| `PluginManager::manifest()` | Capability | Deck-level capability string |
| `ToolSelector::select()` | Capability | RATS: scores tools by relevance + context |
| `ContextRules` | Behavioral | DSL rules → injection text |
| `WorldModel` | Knowledge | Responds to `context.knowledge_request` |
| `Crystallizer` | Knowledge | Crystallized rules → context |
| `Messages::prune_context()` | Compression | Drops unreferenced old turns |
| `Loop::_summarize_tool_output()` | Compression | Summarizes large tool outputs |

## Adding a Context Rule

```perl
my $cr = Clank::ContextRules->new(dsl => <<'DSL');
rule my_rule priority 10
    when /pattern/i
    then inject "Your injection text here"
end
DSL
```

## Adding a Knowledge Source

Subscribe to `context.knowledge_request` on the bus:
```perl
$api->on('context.knowledge_request', sub {
    my ($ev) = @_;
    my $prompt = $ev->{payload}{prompt};
    return { facts => [{ type => 'custom', text => '...' }] };
});
```

## Tool Selection (RATS)

`ToolSelector::select()` scores tools by:
- Base: keyword overlap (TF-based)
- +0.3: recently used tools
- +0.2: tools from loaded wit decks
- +0.15: tools matching file types in recent messages
- +0.25×matches: tools whose hints match error words
