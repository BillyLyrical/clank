# Clank::PerlEnv — The Perl Execution Environment.
#
# The full neurosymbolic loop:
#   1. Code arrives (from LLM, user, or bus event)
#   2. Executes in sandbox (psh_sandbox via Clank::Exec)
#   3. Results update world model (facts, entities)
#   4. Rules engine fires on new facts (forward chaining)
#   5. Output crystallized for next time
#   6. LLM sees updated world state
#
# This is the "Perl shell where LLMs, logic engines, and user code
# collaborate on the blackboard."
package Clank::PerlEnv;
use strict;
use warnings;
use Clank::Util qw(now_ms jencode jdecode);

sub new {
    my ($class, %args) = @_;
    return bless {
        store       => $args{store},
        bus         => $args{bus},
        world_model => $args{world_model},
        engine      => $args{engine},
        crystallizer => $args{crystallizer},
        metrics     => $args{metrics},
        tracer      => $args{tracer},
        timeout     => $args{timeout} // 30,
    }, $class;
}

sub register {
    my ($self, $api) = @_;
    $self->{api} = $api;
    $self->{store} //= $api->store;
    $self->{bus}   //= $api->bus;

    # Lazily create components.
    unless ($self->{world_model}) {
        eval {
            require Clank::WorldModel;
            $self->{world_model} = Clank::WorldModel->new(store => $self->{store});
        };
    }

    # Subscribe directly to the bus (bus-driven, not API-driven).
    $self->{bus}->subscribe('perl.execute', sub { $self->_on_execute(@_) }, name => 'perl_env.execute');
    $self->{bus}->subscribe('perl.eval',    sub { $self->_on_eval(@_) },    name => 'perl_env.eval');

    return $self;
}

# === MAIN EXECUTION ===

sub _on_execute {
    my ($self, $ev) = @_;
    my $code = $ev->{payload}{code} // '';
    my $cid  = $ev->{correlation_id};
    return { ok => 0, error => 'no code provided' } unless length $code;

    my $trace_id;
    $trace_id = $self->{tracer}->start_span('perl_env.execute', topic => 'perl_env')
        if $self->{tracer};

    # Step 1: Execute code in sandbox.
    my $exec_result = $self->_sandbox_execute($code);
    my $stdout = $exec_result->{stdout} // '';
    my $stderr = $exec_result->{stderr} // '';
    my $exit   = $exec_result->{exit_code} // 0;

    unless ($exec_result->{ok}) {
        $self->{metrics}->inc('perl_env.errors') if $self->{metrics};
        $self->{tracer}->end_span($trace_id) if $self->{tracer} && defined $trace_id;
        return {
            ok        => 0,
            stdout    => $stdout,
            stderr    => $stderr,
            exit_code => $exit,
            error     => $exec_result->{error},
        };
    }

    # Step 2: Extract facts from execution result.
    my @facts = $self->_extract_facts($code, $stdout, $exit);

    # Step 3: Update world model with extracted facts.
    my @stored_facts;
    if ($self->{world_model} && @facts) {
        for my $fact (@facts) {
            my $entity_id = $self->{world_model}->add_entity(
                id   => $fact->{entity_id},
                type => $fact->{entity_type} // 'execution_result',
                name => $fact->{entity_name} // $fact->{entity_id},
                attributes => $fact->{attributes} // {},
            );
            my $fact_id = $self->{world_model}->assert_fact(
                entity_id => $entity_id,
                predicate => $fact->{predicate} // 'result',
                value     => $fact->{value} // $stdout,
                confidence => $fact->{confidence} // 0.8,
                source     => 'perl_env',
            );
            push @stored_facts, {
                entity_id   => $entity_id,
                entity_type => $fact->{entity_type},
                fact_id     => $fact_id,
            };
            $self->{metrics}->inc('perl_env.facts_stored') if $self->{metrics};
        }
    }

    # Step 4: Fire rules engine on new facts.
    my @derived;
    if ($self->{engine} && @stored_facts) {
        for my $sf (@stored_facts) {
            my $result = eval {
                $self->{engine}->execute({
                    text  => $stdout,
                    facts => { execution_result => [{ %$sf, stdout => $stdout }] },
                });
            };
            if (defined $result) {
                push @derived, ref $result eq 'HASH' ? $result : { value => "$result" };
                $self->{metrics}->inc('perl_env.derived') if $self->{metrics};
            }
        }
    }

    # Step 5: Publish result event.
    my $result = {
        ok        => 1,
        stdout    => $stdout,
        stderr    => $stderr,
        exit_code => $exit,
        facts     => \@stored_facts,
        derived   => \@derived,
    };

    $self->{bus}->publish('perl_env.result', {
        %$result,
        code_length => length($code),
    }, correlation_id => $cid, sender => 'perl_env') if $self->{bus};

    $self->{metrics}->inc('perl_env.executions') if $self->{metrics};
    $self->{metrics}->inc('perl_env.code_bytes', length($code)) if $self->{metrics};

    if ($self->{tracer} && defined $trace_id) {
        $self->{tracer}->end_span($trace_id, {
            ok => 1, exit_code => $exit,
            facts => scalar @stored_facts,
            derived => scalar @derived,
        });
    }

    return $result;
}

# === QUICK EVAL (no world model side effects) ===

sub _on_eval {
    my ($self, $ev) = @_;
    my $code = $ev->{payload}{code} // '';
    return { ok => 0, error => 'no code provided' } unless length $code;

    my $result = $self->_sandbox_execute($code);
    $self->{metrics}->inc('perl_env.evals') if $self->{metrics};
    return $result;
}

# === SANDBOX EXECUTION ===

sub _sandbox_execute {
    my ($self, $code) = @_;
    require Clank::Exec;
    my $r = Clank::Exec::exec_cmd(
        command => ['perl', '-e', $code],
        timeout => $self->{timeout},
    );

    if ($r->{isError}) {
        return { ok => 0, error => $r->{error} };
    }
    if ($r->{timed_out}) {
        return { ok => 0, error => "timed out after $self->{timeout}s" };
    }

    my $stdout = $r->{stdout} // '';
    my $stderr = $r->{stderr} // '';
    chomp $stdout;
    chomp $stderr;

    return {
        ok        => $r->{exit_code} == 0,
        stdout    => $stdout,
        stderr    => $stderr,
        exit_code => $r->{exit_code},
        error     => ($r->{exit_code} != 0 && length $stderr) ? $stderr : undef,
    };
}

# === FACT EXTRACTION ===

sub _extract_facts {
    my ($self, $code, $stdout, $exit) = @_;
    my @facts;
    my $seq = $self->{_seq}++;

    # Extract from print statements: print "key=value\n"
    while ($stdout =~ /^(\w+)=(.+)$/gm) {
        my ($key, $value) = ($1, $2);
        push @facts, {
            entity_id   => "exec_${seq}_$key",
            entity_type => 'key_value',
            entity_name => $key,
            predicate   => 'has_value',
            value       => $value,
            confidence  => 0.9,
            attributes  => { key => $key, source_code => substr($code, 0, 200) },
        };
    }

    # Extract JSON output.
    if ($stdout =~ /^\s*\{/) {
        my $data = eval { jdecode($stdout) };
        if (ref $data eq 'HASH') {
            push @facts, {
                entity_id   => "exec_json_${seq}",
                entity_type => 'json_result',
                entity_name => 'json_output',
                predicate   => 'result',
                value       => $stdout,
                confidence  => 0.85,
                attributes  => { %$data, source_code => substr($code, 0, 200) },
            };
        }
    }

    # Always store the execution as a fact.
    push @facts, {
        entity_id   => "exec_${seq}",
        entity_type => 'execution',
        entity_name => 'last_execution',
        predicate   => 'output',
        value       => substr($stdout, 0, 500),
        confidence  => 0.7,
        attributes  => {
            exit_code   => $exit,
            code_hash   => Digest::SHA::sha256_hex($code),
            code_length => length($code),
        },
    };

    return @facts;
}

1;
