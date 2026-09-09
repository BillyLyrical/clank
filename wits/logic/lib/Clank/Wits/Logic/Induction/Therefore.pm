# CLANK-WIT: name=Therefore
# CLANK-WIT: version=1.0.0
# CLANK-WIT: about=Draw a conclusion from facts and theorems
# CLANK-WIT: usage=Input: { facts: [...], theorems: [...], conclusion: "..." } Output: { conclusion: "...", confidence: 0.0-1.0, based_on: { facts: [...], theorems: [...] } }
# CLANK-WIT: hint=induction_therefore, therefore, conclusion, inference, derive
# CLANK-WIT: author=Clank
# CLANK-WIT: license=Artistic-2.0
package Clank::Wits::Logic::Induction::Therefore;
use strict;
use warnings;

my %_state;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'induction.therefore',
        description => 'Draw a conclusion from facts and theorems',
        parameters  => {
            type       => 'object',
            properties => {
                conclusion => { type => 'string', description => 'The conclusion to draw' },
                facts      => { type => 'array',  description => 'Facts supporting the conclusion' },
                theorems   => { type => 'array',  description => 'Theorems applied' },
                confidence => { type => 'number', description => 'Confidence 0.0-1.0' },
            },
            required => ['conclusion'],
        },
        execute => sub {
            my ($args) = @_;
            my $input = $args;
            my %ctx = (state => \%_state);

            my $conclusion = ref $input eq 'HASH' ? ($input->{conclusion} // '') : $input;
            my $facts      = ref $input eq 'HASH' ? ($input->{facts} // []) : [];
            my $theorems   = ref $input eq 'HASH' ? ($input->{theorems} // []) : [];
            my $confidence = ref $input eq 'HASH' ? ($input->{confidence} // 0.5) : 0.5;

            return { error => "No conclusion provided" } unless $conclusion;

            my $state = $ctx{state} // {};
            my $next_id = ($state->{therefore_count} // 0) + 1;
            $state->{therefore_count} = $next_id;
            $state->{conclusions} //= [];
            push @{$state->{conclusions}}, {
                id         => $next_id,
                conclusion => $conclusion,
                facts      => $facts,
                theorems   => $theorems,
                confidence => $confidence,
                timestamp  => scalar localtime,
            };

            return {
                therefore_id => $next_id,
                conclusion   => $conclusion,
                confidence   => $confidence,
                based_on     => {
                    facts    => [ map { ref $_ eq 'HASH' ? $_->{fact_id} // $_->{data} : $_ } @$facts ],
                    theorems => [ map { ref $_ eq 'HASH' ? $_->{theorem_id} // $_->{principle} : $_ } @$theorems ],
                },
            };
        },
    );
}

1;
