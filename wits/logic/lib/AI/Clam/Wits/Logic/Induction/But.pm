# CLAM-WIT: name=But
# CLAM-WIT: version=1.0.0
# CLAM-WIT: about=Raise an objection or caveat to a conclusion
# CLAM-WIT: usage=Input: { conclusion: "...", exception: "...", strength: 0.0-1.0 } Output: { revised: "...", strength: 0.0-1.0, objection: "..." }
# CLAM-WIT: hint=induction_but, but, objection, caveat, challenge, exception
# CLAM-WIT: author=CLAM
# CLAM-WIT: license=Artistic-2.0
package AI::Clam::Wits::Logic::Induction::But;
use strict;
use warnings;

my %_state;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'induction.but',
        description => 'Raise an objection or caveat to a conclusion',
        parameters  => {
            type       => 'object',
            properties => {
                conclusion => { type => 'string', description => 'The conclusion being challenged' },
                exception  => { type => 'string', description => 'The objection or caveat' },
                strength   => { type => 'number', description => 'Strength of objection 0.0-1.0' },
            },
        },
        execute => sub {
            my ($args) = @_;
            my $input = $args;
            my %ctx = (state => \%_state);

            my $conclusion = ref $input eq 'HASH' ? ($input->{conclusion} // '') : '';
            my $exception  = ref $input eq 'HASH' ? ($input->{exception} // '') : $input;
            my $strength   = ref $input eq 'HASH' ? ($input->{strength} // 0.5) : 0.5;

            return { error => "No objection provided" } unless $exception;

            my $state = $ctx{state} // {};
            my $next_id = ($state->{but_count} // 0) + 1;
            $state->{but_count} = $next_id;
            $state->{objections} //= [];
            push @{$state->{objections}}, {
                id         => $next_id,
                conclusion => $conclusion,
                exception  => $exception,
                strength   => $strength,
                timestamp  => scalar localtime,
            };

            my $revised = $conclusion;
            if ($conclusion && $strength > 0.5) {
                $revised = "$conclusion (but: $exception)";
            } elsif ($conclusion) {
                $revised = "$conclusion [note: $exception]";
            }

            return {
                but_id    => $next_id,
                revised   => $revised,
                strength  => $strength,
                objection => $exception,
                against   => $conclusion,
            };
        },
    );
}

1;
