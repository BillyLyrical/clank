package Clank::Provider::Mock;
use strict; use warnings;
use parent 'Clank::Provider';
# Deterministic offline provider: echoes the last user message back as a final
# assistant turn. No network, no model — for smoke tests, CI without access to
# an LLM endpoint, and protocol testing of clankd. Every request payload is
# recorded in ->calls for assertions (context continuity etc.).

sub new {
    my ($class, %o) = @_;
    my $s = $class->SUPER::new(%o);
    $s->{name}  //= 'mock';
    $s->{calls} = [];
    return $s;
}

sub calls { @{ $_[0]->{calls} } }

sub post_json {
    my ($self, $path, $payload) = @_;
    push @{ $self->{calls} }, $payload;
    my (@user_texts);
    for my $m (@{ $payload->{messages} // [] }) {
        next unless ($m->{role} // '') eq 'user';
        push @user_texts, $m->{content} if defined $m->{content} && !ref($m->{content});
    }
    my $text = @user_texts ? "mock: $user_texts[-1]" : 'mock (no user message)';
    return { choices => [ { finish_reason => 'stop', message => { content => $text } } ] };
}

1;
