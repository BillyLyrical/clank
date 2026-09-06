# CLAM-WIT: name=Because
# CLAM-WIT: version=1.0.0
# CLAM-WIT: about=State a causal relationship — X because Y
# CLAM-WIT: usage=Input: { effect: "server crashed", cause: "OOM", strength: 0.9, evidence: [...] } Output: { because_id: 1, effect: "...", cause: "...", strength: 0.9, causal_link: "server crashed because OOM" }
# CLAM-WIT: hint=induction_because, because, causal, cause_effect, causation
# CLAM-WIT: author=CLAM
# CLAM-WIT: license=Artistic-2.0
package Clam::Wits::Logic::Induction::Because;
use strict;
use warnings;

my %_state;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'induction.because',
        description => 'State a causal relationship — X because Y',
        parameters  => {
            type       => 'object',
            properties => {
                effect   => { type => 'string', description => 'The effect' },
                cause    => { type => 'string', description => 'The cause' },
                strength => { type => 'number', description => 'Causal strength 0.0-1.0' },
                evidence => { type => 'array',  description => 'Supporting evidence' },
                type     => { type => 'string', description => 'Causal type: direct, contributing, necessary, sufficient' },
            },
            required => ['effect', 'cause'],
        },
        execute => sub {
            my ($args) = @_;
            my $input = $args;
            my %ctx = (state => \%_state);

            ref $input eq 'HASH' or return { error => "Input must be a hash" };

            my $effect   = $input->{effect} // '';
            my $cause    = $input->{cause}  // '';
            my $strength = $input->{strength} // 0.5;
            my $evidence = $input->{evidence} // [];
            my $type     = $input->{type} // 'direct';

            $effect or return { error => "No effect provided" };
            $cause  or return { error => "No cause provided" };

            my $state = $ctx{state} // {};
            my $next_id = ($state->{because_count} // 0) + 1;
            $state->{because_count} = $next_id;
            $state->{causal_links} //= [];
            push @{$state->{causal_links}}, {
                id        => $next_id,
                effect    => $effect,
                cause     => $cause,
                strength  => $strength,
                evidence  => $evidence,
                type      => $type,
                timestamp => scalar localtime,
            };

            my $link = "$effect because $cause";
            if ($strength < 0.3) {
                $link = "$effect possibly because $cause";
            } elsif ($strength < 0.7) {
                $link = "$effect likely because $cause";
            }

            return {
                because_id   => $next_id,
                effect       => $effect,
                cause        => $cause,
                strength     => $strength,
                type         => $type,
                causal_link  => $link,
                evidence_count => scalar @$evidence,
            };
        },
    );
}

1;
