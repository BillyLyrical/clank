# Clank::Bus::Events — central event vocabulary for the bus.
#
# Defines every bus topic with payload schema, description, and
# backward-compatible aliases. Wits and core modules should import
# this module to reference topic names as constants.
#
# Naming convention: <noun>.<verb> or <noun>_<verb>
#   Lifecycle:  session_start, agent_start, turn_start
#   Tool:       pre_tool_use, post_tool_use, post_tool_use_failure
#   Context:    context.knowledge_request, context.procedural_guidance
#   Subagent:   subagent_start, subagent_stop
#   Agent:      pre_agent_start, agent_end, agent_delegate
package Clank::Bus::Events;
use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(event_info event_topic %EVENTS);

# === EVENT CATALOG ===
# Key: canonical topic name
# Value: { description, payload => { field => desc }, category }

our %EVENTS = (

    # --- Session lifecycle ---
    session_start => {
        category    => 'session',
        description => 'Session created or resumed',
        payload     => { session_id => 'string' },
    },
    session_end => {
        category    => 'session',
        description => 'Session closing',
        payload     => { session_id => 'string' },
    },

    # --- Prompt lifecycle ---
    user_prompt_submit => {
        category    => 'prompt',
        description => 'User input received (before agent processes)',
        payload     => { text => 'string', source => 'string' },
    },

    # --- Agent lifecycle ---
    before_agent_start => {
        category    => 'agent',
        description => 'Before agent loop begins (can modify prompt/system prompt)',
        payload     => { prompt => 'string', systemPrompt => 'string' },
    },
    agent_start => {
        category    => 'agent',
        description => 'Agent loop begins processing',
        payload     => { prompt => 'string', session_id => 'string' },
    },
    agent_end => {
        category    => 'agent',
        description => 'Agent loop finishes',
        payload     => { session_id => 'string', error => 'string', escalated => 'boolean' },
    },
    agent_settled => {
        category    => 'agent',
        description => 'Agent fully settled (post-compaction, post-cleanup)',
        payload     => {},
    },

    # --- Turn lifecycle ---
    turn_start => {
        category    => 'turn',
        description => 'Individual turn begins',
        payload     => { turn => 'integer', session_id => 'string' },
    },
    turn_end => {
        category    => 'turn',
        description => 'Individual turn ends',
        payload     => { turn => 'integer', throttled => 'boolean', escalated => 'boolean' },
    },

    # --- Tool lifecycle ---
    pre_tool_use => {
        category    => 'tool',
        description => 'Before tool execution (can block via { block => 1 })',
        payload     => { toolCallId => 'string', name => 'string', input => 'hash' },
    },
    post_tool_use => {
        category    => 'tool',
        description => 'After tool success (output mutable)',
        payload     => { toolCallId => 'string', name => 'string', output => 'string', isError => 'boolean' },
    },
    post_tool_use_failure => {
        category    => 'tool',
        description => 'After tool failure',
        payload     => { toolCallId => 'string', name => 'string', output => 'string', error => 'string' },
    },
    tool_execution_start => {
        category    => 'tool',
        description => 'Tool begins executing (informational)',
        payload     => { toolCallId => 'string', name => 'string', input => 'hash' },
    },
    tool_execution_end => {
        category    => 'tool',
        description => 'Tool execution complete (informational)',
        payload     => { toolCallId => 'string', name => 'string', isError => 'boolean' },
    },
    observation => {
        category    => 'tool',
        description => 'Tool use observation for instinct learning',
        payload     => { tool => 'string', input => 'hash', output => 'string', success => 'boolean' },
    },

    # --- Context lifecycle ---
    context => {
        category    => 'context',
        description => 'Context assembly (messages + system prompt mutable)',
        payload     => { messages => 'array', system_prompt => 'string' },
    },
    context_knowledge_request => {
        category    => 'context',
        description => 'Knowledge retrieval from WorldModel + Crystallizer',
        payload     => { prompt => 'string' },
    },
    context_procedural_guidance => {
        category    => 'context',
        description => 'Procedural graph guidance for current action',
        payload     => { last_action => 'string', prompt => 'string' },
    },
    before_provider_request => {
        category    => 'context',
        description => 'Before LLM call (payload mutable)',
        payload     => { payload => 'hash' },
    },
    after_provider_response => {
        category    => 'context',
        description => 'After LLM response (informational)',
        payload     => { status => 'integer', usage => 'hash', stop_reason => 'string' },
    },
    message_end => {
        category    => 'context',
        description => 'Assistant message finalized (content mutable)',
        payload     => { role => 'string', content => 'hash' },
    },
    message_update => {
        category    => 'context',
        description => 'Streaming delta from provider',
        payload     => { delta => 'hash' },
    },

    # --- Compaction lifecycle ---
    pre_compact => {
        category    => 'compaction',
        description => 'Before context compaction (can veto)',
        payload     => { session_id => 'string', est_tokens => 'integer' },
    },
    post_compact => {
        category    => 'compaction',
        description => 'After context compaction',
        payload     => { session_id => 'string', before_tokens => 'integer', after_tokens => 'integer' },
    },

    # --- Subagent lifecycle ---
    subagent_start => {
        category    => 'subagent',
        description => 'Subagent spawned',
        payload     => { parent_session_id => 'string', child_session_id => 'string', prompt => 'string' },
    },
    subagent_stop => {
        category    => 'subagent',
        description => 'Subagent completed',
        payload     => { parent_session_id => 'string', child_session_id => 'string', ok => 'boolean', turns => 'integer' },
    },

    # --- Agent lifecycle ---
    pre_agent_start => {
        category    => 'agent',
        description => 'Agent profile loaded, before loop runs',
        payload     => { parent_session_id => 'string', child_session_id => 'string', agent => 'string', model => 'string' },
    },
    agent_end => {
        category    => 'agent',
        description => 'Agent execution completed',
        payload     => { parent_session_id => 'string', child_session_id => 'string', ok => 'boolean', turns => 'integer', agent => 'string', model => 'string' },
    },
    agent_delegate => {
        category    => 'agent',
        description => 'One agent delegates to another',
        payload     => { from_agent => 'string', to_agent => 'string', prompt => 'string' },
    },

    # --- Escalation ---
    escalation_check => {
        category    => 'escalation',
        description => 'Check if prompt needs escalation',
        payload     => { prompt => 'string' },
    },

    # --- Mesh / Director / Band ---
    mesh_broadcast => {
        category    => 'mesh',
        description => 'Mesh network broadcast message',
        payload     => { envelope => 'hash' },
    },
    director_done => {
        category    => 'director',
        description => 'Director completed',
        payload     => { result => 'any' },
    },
    band_discover => {
        category    => 'band',
        description => 'Band discovery',
        payload     => { query => 'string' },
    },

    # --- Metrics ---
    metrics_self_stats => {
        category    => 'metrics',
        description => 'Metrics self-stats query',
        payload     => {},
    },
);

# === API ===

sub event_info {
    my ($topic) = @_;
    return $EVENTS{$topic};
}

sub event_topic {
    my ($topic) = @_;
    return $topic;
}

1;
