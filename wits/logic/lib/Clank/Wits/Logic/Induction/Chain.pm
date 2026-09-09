# CLANK-WIT: name=Chain
# CLANK-WIT: version=1.0.0
# CLANK-WIT: about=Orchestrate an inductive reasoning chain — facts through conclusions
# CLANK-WIT: usage=Input: { steps: [{ type: "fact", data: "..." }, { type: "theorem", principle: "..." }, ...] } Output: { chain: [...], summary: "...", confidence: 0.0-1.0, step_count: N }
# CLANK-WIT: hint=induction_chain, chain, orchestrate, reasoning, pipeline
# CLANK-WIT: author=Clank
# CLANK-WIT: license=Artistic-2.0
package Clank::Wits::Logic::Induction::Chain;
use strict;
use warnings;

my %_state;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'induction.chain',
        description => 'Orchestrate an inductive reasoning chain — facts through conclusions',
        parameters  => {
            type       => 'object',
            properties => {
                steps => { type => 'array', description => 'Array of reasoning steps' },
            },
            required => ['steps'],
        },
        execute => sub {
            my ($args) = @_;
            my $input = $args;
            my %ctx = (state => \%_state);

            my $steps = ref $input eq 'HASH' ? ($input->{steps} // []) : [];
            my $wits  = $ctx{wits};

            return { error => "No steps provided" } unless @$steps;
            return { error => "No wits available to execute steps" } unless $wits;

            my @chain;
            my @facts;
            my @theorems;
            my $conclusion = '';
            my $confidence = 0.5;
            my $last_result;

            for my $step (@$steps) {
                my $type     = $step->{type} // 'observation';
                my $wit_name = "induction.$type";

                my $result = eval { $wits->execute($wit_name, $step, %ctx) };
                if ($@ || !$result) {
                    push @chain, {
                        step   => scalar @chain + 1,
                        type   => $type,
                        input  => $step,
                        error  => $@ || "wit returned undef",
                        status => 'failed',
                    };
                    next;
                }

                $result->{_step} = scalar @chain + 1;
                $result->{_type} = $type;
                push @chain, $result;
                $last_result = $result;

                if ($type eq 'fact') {
                    push @facts, $result;
                } elsif ($type eq 'theorem') {
                    push @theorems, $result;
                } elsif ($type eq 'therefore') {
                    $conclusion = $result->{conclusion} // '';
                    $confidence = $result->{confidence} // 0.5;
                } elsif ($type eq 'but') {
                    $conclusion = $result->{revised} // $conclusion;
                    $confidence *= (1 - ($result->{strength} // 0.5));
                } elsif ($type eq 'maybe') {
                    $confidence = $result->{confidence} // $confidence;
                }
            }

            my $summary = $conclusion || 'No conclusion reached';
            if ($confidence < 0.3) {
                $summary = "Weak: $summary";
            } elsif ($confidence >= 0.8) {
                $summary = "Strong: $summary";
            }

            return {
                chain      => \@chain,
                summary    => $summary,
                confidence => $confidence,
                step_count => scalar @chain,
                facts      => scalar @facts,
                theorems   => scalar @theorems,
            };
        },
    );
}

1;
