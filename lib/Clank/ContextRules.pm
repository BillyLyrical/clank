# Clank::ContextRules — deterministic context injection via Rules DSL.
#
# Defines rules that inject behavioral context into the system prompt based
# on the current task. No LLM call needed — pure regex matching.
#
# (docs/CONTEXT.md §4.3 — Behavioral Context Pipeline)
package Clank::ContextRules;
use strict;
use warnings;
use Clank::Rules::DSL;

# Default context rules: regex → injection text.
# These are always evaluated against the current prompt + file context.
my $DEFAULT_RULES_DSL = <<'DSL';
rule inject_perl_style priority 10
    when /(?:edit|write|create|modify)\s+.*\.(?:pm|pl|t|xs)\b/i
    then inject Always use strict and warnings in Perl code.
    then inject Prefer 'use parent' over 'use base' for inheritance.
end

rule inject_perl_modern priority 10
    when /(?:edit|write|create)\s+.*\.pm\b/i
    then inject Use modern Perl features: signatures, try/catch (Syntax::Keyword::Try), given/when.
end

rule inject_db_context priority 8
    when /(?:database|query|sql|table|schema|join|select|insert|update|delete)/i
    then inject Database tools available: db_connect, db_query, db_execute, db_schema, db_shell.
end

rule inject_git_context priority 8
    when /(?:git|commit|branch|merge|rebase|stash|diff|blame|log)/i
    then inject Git tools available: git_status, git_commit, git_diff, git_log, git_blame, git_branch, git_stash.
end

rule inject_test_context priority 8
    when /(?:test|spec|prove|assert|verify|check)/i
    then inject Test tools: perl_syntax, perl_test, perl_testgen. Run tests with: prove -l t/
end

rule inject_logic_context priority 7
    when /(?:datalog|logic|deduce|infer|prove|axiom|theorem|SAT|constraint)/i
    then inject Logic tools: datalog_query, deduction_axiom, deduction_rule, induction_fact, sat_solve.
end

rule inject_security.priority 6
    when /(?:security|vulnerability|exploit|injection|XSS|CSRF|auth)/i
    then inject Security: never log secrets, validate input at system boundaries, use taint mode for untrusted data.
end

rule inject_conciseness priority 5
    when /(?:concise|brief|short|terse|summarize)/i
    then inject Be concise. Minimize output tokens. One-line answers preferred when possible.
end

rule inject_no_comments priority 5
    when /(?:no.?comment|without.?comment|skip.?comment)/i
    then inject Do NOT add comments to code unless explicitly requested.
end

DSL

sub new {
    my ($class, %args) = @_;
    my $self = bless {
        rules      => [],
        extra_dsl  => $args{dsl} // '',
    }, $class;
    $self->_load_rules;
    return $self;
}

sub _load_rules {
    my ($self) = @_;
    my $dsl = $DEFAULT_RULES_DSL . ($self->{extra_dsl} // '');
    $self->{rules} = Clank::Rules::DSL->parse($dsl);
}

# Evaluate rules against the current context. Returns arrayref of injection
# strings from matching rules. Context keys: prompt, file_types, loaded_wits.
sub evaluate {
    my ($self, %context) = @_;
    my @injections;
    my $text = $context{prompt} // '';

    for my $rule (@{ $self->{rules} }) {
        next unless $rule->{enabled};
        my $result = $rule->test({ text => $text });
        if ($result) {
            my $action = $rule->execute({ text => $text, %context });
            if ($action && ref $action eq 'HASH' && $action->{inject}) {
                push @injections, @{ $action->{inject} };
            }
        }
    }

    return \@injections;
}

# Format injections as a block for the system prompt.
sub format_for_prompt {
    my ($self, %context) = @_;
    my $injections = $self->evaluate(%context);
    return '' unless @$injections;

    my @lines = ("Rules for this task:");
    for my $inj (@$injections) {
        push @lines, "- $inj";
    }
    return join("\n", @lines);
}

1;
