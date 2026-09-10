# CLANK-WIT: name=Council
# CLANK-WIT: version=1.0.0
# CLANK-WIT: about=Four-voice adversarial decision-making for ambiguous choices
# CLANK-WIT: usage=Input: { question: string, context?: string } Output: formatted council verdict with 4 positions + synthesis
# CLANK-WIT: hint=council, adversarial, decision, multiple perspectives, tradeoffs, go no go, dissent
# CLANK-WIT: author=Clank
# CLANK-WIT: license=Artistic-2.0
#
# Four-voice council for decisions under ambiguity:
#   Architect (constructive), Skeptic (critical), Pragmatist (practical), Critic (quality)
# Each voice sees only the question + context — no conversation history (anti-anchoring).
package Clank::Wits::Build::Council;
use strict;
use warnings;

my %ROLES = (
    skeptic   => {
        lens    => 'challenge framing, question assumptions, propose the simplest credible alternative',
        emphasis => 'You are the Skeptic. Your job is to challenge the premise. Question whether the problem is real, whether the constraints are actual, and whether the simplest solution has been considered.',
    },
    pragmatist => {
        lens    => 'shipping speed, user impact, operational reality',
        emphasis => 'You are the Pragmatist. Your job is to optimize for speed, simplicity, and real-world execution. What can ship now? What creates the least operational burden?',
    },
    critic    => {
        lens    => 'edge cases, downside risk, failure modes',
        emphasis => 'You are the Critic. Your job is to surface downside risk, edge cases, and reasons the plan could fail. What could go wrong? What are we not seeing?',
    },
);

my $VOICE_PROMPT = <<'END_PROMPT';
You are the %s on a four-voice decision council.

Question:
%s

Context:
%s

Respond with:
1. Position — 1-2 sentences
2. Reasoning — 3 concise bullets
3. Risk — biggest risk in your recommendation
4. Surprise — one thing the other voices may miss

Be direct. No hedging. Keep it under 300 words.
END_PROMPT

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'council',
        description => 'Convene a 4-voice adversarial council for ambiguous decisions. Spawns 3 independent subagents (Skeptic, Pragmatist, Critic) plus the Architect position, then synthesizes a verdict.',
        parameters  => {
            type       => 'object',
            properties => {
                question => { type => 'string', description => 'The decision question to council on' },
                context  => { type => 'string', description => 'Relevant context (code snippets, constraints, metrics). Keep compact.' },
            },
            required => ['question'],
        },
        execute => sub {
            my ($args) = @_;
            my $question = $args->{question} // '';
            my $context  = $args->{context}  // 'No additional context provided.';

            return { error => 'No question provided' } unless length $question;

            my @voices;
            for my $role (qw(skeptic pragmatist critic)) {
                my $role_info = $ROLES{$role};
                my $prompt = sprintf($VOICE_PROMPT,
                    ucfirst($role),
                    $question,
                    $context,
                );
                $prompt .= "\n\n" . $role_info->{emphasis};

                push @voices, {
                    role   => $role,
                    prompt => $prompt,
                };
            }

            return {
                voices     => \@voices,
                question   => $question,
                instruction => 'Spawn 3 subagents with the voices above, collect results, then synthesize per the council format.',
            };
        },
    );

    $api->register_command('council',
        description => 'council: display council verdict format reference',
        handler => sub {
            return _format_reference();
        },
    );
}

sub _format_reference {
    return <<'END_FORMAT';
## Council Verdict Format

**Architect:** [1-2 sentence position]
[1 line on why]

**Skeptic:** [1-2 sentence position]
[1 line on why]

**Pragmatist:** [1-2 sentence position]
[1 line on why]

**Critic:** [1-2 sentence position]
[1 line on why]

### Verdict
- **Consensus:** [where they align]
- **Strongest dissent:** [most important disagreement]
- **Premise check:** [did the Skeptic challenge the question itself?]
- **Recommendation:** [the synthesized path]
END_FORMAT
}

1;
