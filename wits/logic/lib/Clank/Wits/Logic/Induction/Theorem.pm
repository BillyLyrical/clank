# CLANK-WIT: name=Theorem
# CLANK-WIT: version=1.0.0
# CLANK-WIT: about=State a theorem — a rule, principle, or heuristic
# CLANK-WIT: usage=Input: { principle: "YAGNI: don't add code until needed", when: "design review" } Output: { theorem_id: 1, principle: "...", when: "...", confidence: 1.0 }
# CLANK-WIT: hint=induction_theorem, theorem, principle, rule, heuristic
# CLANK-WIT: author=Clank
# CLANK-WIT: license=Artistic-2.0
package Clank::Wits::Logic::Induction::Theorem;
use strict;
use warnings;

my %_state;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'induction.theorem',
        description => 'State a theorem — a rule, principle, or heuristic',
        parameters  => {
            type       => 'object',
            properties => {
                principle  => { type => 'string', description => 'The principle or rule' },
                when       => { type => 'string', description => 'When to apply this theorem' },
                confidence => { type => 'number', description => 'Confidence 0.0-1.0' },
            },
            required => ['principle'],
        },
        execute => sub {
            my ($args) = @_;
            my $input = $args;
            my %ctx = (state => \%_state);

            my $principle  = ref $input eq 'HASH' ? ($input->{principle} // '') : $input;
            my $when       = ref $input eq 'HASH' ? ($input->{when} // 'general') : 'general';
            my $confidence = ref $input eq 'HASH' ? ($input->{confidence} // 1.0) : 1.0;

            return { error => "No principle provided" } unless $principle;

            my $state = $ctx{state} // {};
            my $next_id = ($state->{theorem_count} // 0) + 1;
            $state->{theorem_count} = $next_id;
            $state->{theorems} //= [];
            push @{$state->{theorems}}, {
                id         => $next_id,
                principle  => $principle,
                when       => $when,
                confidence => $confidence,
                timestamp  => scalar localtime,
            };

            return {
                theorem_id => $next_id,
                principle  => $principle,
                when       => $when,
                confidence => $confidence,
            };
        },
    );
}

1;
