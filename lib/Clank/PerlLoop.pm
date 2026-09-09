# Clank::PerlLoop — agent loop connecting LLM to PerlEnv.
#
# The code generation loop:
#   1. Task arrives (from user, LLM, or bus event)
#   2. LLM generates Perl code
#   3. PerlEnv executes in sandbox
#   4. Results fed back to LLM
#   5. LLM refines or declares success
#   6. Repeat until done or max iterations
#
# This is the bridge between "LLM thinks" and "PerlEnv does."
# The LLM proposes code; the sandbox executes it; the world model
# records what happened; the LLM observes and iterates.
package Clank::PerlLoop;
use strict;
use warnings;
use Clank::Util qw(now_ms jencode jdecode);

sub new {
    my ($class, %args) = @_;
    return bless {
        store       => $args{store},
        bus         => $args{bus},
        provider    => $args{provider},
        session     => $args{session},
        perl_env    => $args{perl_env},
        metrics     => $args{metrics},
        tracer      => $args{tracer},
        max_iters   => $args{max_iters} // 10,
        timeout     => $args{timeout}   // 30,
    }, $class;
}

sub register {
    my ($self, $api) = @_;
    $self->{api} = $api;
    $self->{store} //= $api->store;
    $self->{bus}   //= $api->bus;

    # Subscribe to perl_loop.run — the main entry point.
    $self->{bus}->subscribe('perl_loop.run', sub { $self->_on_run(@_) }, name => 'perl_loop.run');

    return $self;
}

# === MAIN LOOP ===

sub _on_run {
    my ($self, $ev) = @_;
    my $task    = $ev->{payload}{task} // '';
    my $context = $ev->{payload}{context} // '';
    my $cid     = $ev->{correlation_id};
    my $max     = $ev->{payload}{max_iters} // $self->{max_iters};

    return { ok => 0, error => 'no task provided' } unless length $task;
    return { ok => 0, error => 'no provider' } unless $self->{provider};
    return { ok => 0, error => 'no session' } unless $self->{session};

    my $trace_id;
    $trace_id = $self->{tracer}->start_span('perl_loop.run', topic => 'perl_loop')
        if $self->{tracer};

    my @history;          # iteration history
    my $success = 0;
    my $final_code = '';
    my $final_output = '';

    for my $iter (1 .. $max) {
        my $iter_span;
        $iter_span = $self->{tracer}->start_span("perl_loop.iter.$iter", topic => 'perl_loop')
            if $self->{tracer};

        # Build the prompt for this iteration.
        my $prompt = $self->_build_prompt($task, $context, \@history, $iter);

        # Ask the LLM to generate code.
        my $code = $self->_generate_code($prompt);
        unless (defined $code && length $code) {
            push @history, { iter => $iter, code => '', output => '', error => 'LLM returned no code' };
            last;
        }

        $self->{bus}->publish('perl_loop.code', {
            task  => $task, iter => $iter, code => $code,
        }, correlation_id => $cid, sender => 'perl_loop');

        # Execute via PerlEnv (sandboxed, world model update).
        my $exec_result = $self->_execute_code($code);

        my $output = $exec_result->{stdout} // '';
        my $error  = $exec_result->{error} // '';
        my $ok     = $exec_result->{ok} // 0;

        push @history, {
            iter   => $iter,
            code   => $code,
            output => $output,
            error  => $error,
            ok     => $ok,
        };

        $self->{bus}->publish('perl_loop.iteration', {
            task    => $task,
            iter    => $iter,
            code    => $code,
            output  => $output,
            error   => $error,
            ok      => $ok,
            facts   => $exec_result->{facts} // [],
        }, correlation_id => $cid, sender => 'perl_loop');

        $self->{metrics}->inc('perl_loop.iterations') if $self->{metrics};

        # Check if the LLM declares success.
        if ($ok && $self->_check_success($task, $output, $code)) {
            $success = 1;
            $final_code = $code;
            $final_output = $output;
            last;
        }

        # Check for explicit failure signal.
        if ($output =~ /^(?:FAIL|ERROR|IMPOSSIBLE)\b/i) {
            $final_output = $output;
            last;
        }

        $final_code = $code;
        $final_output = $output;
    }

    my $result = {
        ok         => $success,
        code       => $final_code,
        output     => $final_output,
        iterations => scalar @history,
        history    => \@history,
    };

    $self->{bus}->publish('perl_loop.done', {
        %$result, task => $task,
    }, correlation_id => $cid, sender => 'perl_loop');

    $self->{metrics}->inc('perl_loop.runs') if $self->{metrics};
    $self->{metrics}->inc('perl_loop.successes') if $self->{metrics} && $success;

    if ($self->{tracer} && defined $trace_id) {
        $self->{tracer}->end_span($trace_id, {
            ok => $success, iterations => scalar @history,
        });
    }

    return $result;
}

# === PROMPT BUILDING ===

sub _build_prompt {
    my ($self, $task, $context, $history, $iter) = @_;

    my $prompt = "You are a Perl code generator. Write Perl code to accomplish the task.\n\n";
    $prompt .= "Task: $task\n";
    $prompt .= "Context: $context\n" if length $context;
    $prompt .= "\nRules:\n";
    $prompt .= "- Output ONLY the Perl code, no explanations\n";
    $prompt .= "- Use 'print' to output results\n";
    $prompt .= "- Print key=value pairs for structured output (e.g., print \"count=42\\n\")\n";
    $prompt .= "- Print JSON for complex results (e.g., print encode_json({...}))\n";
    $prompt .= "- Exit 0 on success, non-zero on failure\n";
    $prompt .= "- Print 'SUCCESS' on the last line if the task is complete\n";
    $prompt .= "- Print 'FAIL: reason' if the task cannot be completed\n";

    if (@$history) {
        $prompt .= "\nPrevious attempts:\n";
        for my $h (@$history) {
            $prompt .= sprintf("\n--- Iteration %d ---\n", $h->{iter});
            $prompt .= "Code:\n$h->{code}\n" if length($h->{code} // '');
            if (length($h->{output} // '')) {
                $prompt .= "Output: $h->{output}\n";
            }
            if (length($h->{error} // '')) {
                $prompt .= "Error: $h->{error}\n";
            }
            $prompt .= "Status: " . ($h->{ok} ? "success" : "failed") . "\n";
        }
        $prompt .= "\nFix the issues and try again. Previous attempts failed.\n";
    }

    return $prompt;
}

# === LLM CODE GENERATION ===

sub _generate_code {
    my ($self, $prompt) = @_;
    my $provider = $self->{provider};
    my $session  = $self->{session};

    # Build a minimal message array for the provider.
    my $messages = [
        { role => 'system', content => 'You are a Perl code generator. Output only Perl code.' },
        { role => 'user',   content => $prompt },
    ];

    my $payload = $provider->chat_payload(
        messages => $messages,
        tools    => [],
    );

    my $resp;
    eval { $resp = $provider->chat($payload) };
    return undef if $@ || !$resp;

    my $content = $resp->{choices}[0]{message}{content} // '';
    # Strip markdown code fences if present.
    $content =~ s/^```(?:perl)?\s*\n//;
    $content =~ s/\n```\s*$//;
    $content =~ s/^\s+|\s+$//g;

    return $content;
}

# === CODE EXECUTION ===

sub _execute_code {
    my ($self, $code) = @_;
    require Clank::Exec;
    my $r = Clank::Exec::exec_cmd(
        command => ['perl', '-e', $code],
        timeout => $self->{timeout},
    );

    my $stdout = $r->{stdout} // '';
    my $stderr = $r->{stderr} // '';
    chomp $stdout;
    chomp $stderr;

    my $ok = ($r->{exit_code} // 1) == 0 && $stdout !~ /^FAIL\b/i;

    # Publish to PerlEnv for world model update.
    if ($self->{bus}) {
        $self->{bus}->publish('perl.execute', {
            code    => $code,
            _silent => 1,   # don't trigger the full PerlEnv pipeline again
        });
    }

    return {
        ok        => $ok,
        stdout    => $stdout,
        stderr    => $stderr,
        exit_code => $r->{exit_code} // -1,
        error     => ($r->{exit_code} || 0) != 0 ? $stderr : undef,
    };
}

# === SUCCESS CHECK ===

sub _check_success {
    my ($self, $task, $output, $code) = @_;
    # Success if output contains SUCCESS keyword.
    return 1 if $output =~ /^SUCCESS\b/m;
    # Success if exit code was 0 and output is non-empty.
    return 1 if length($output) > 0 && $output !~ /^(?:FAIL|ERROR)\b/m;
    return 0;
}

1;
