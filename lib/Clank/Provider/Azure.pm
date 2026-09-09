package Clank::Provider::Azure;
use strict; use warnings;
use parent 'Clank::Provider';
# Azure OpenAI — same protocol as OpenAI but different endpoint structure.
# Required: api_version (default 2024-10-21-preview).
# base_url format: https://{resource}.openai.azure.com/openai/deployments/{deployment}

sub new {
    my ($c, %o) = @_;
    my $self = $c->SUPER::new(%o);
    $self->{api_version} //= $o{api_version} // $ENV{CLAM_AZURE_API_VERSION} // '2024-10-21-preview';
    return $self;
}

# Override path to include api-version query param
sub chat_payload {
    my ($self, %a) = @_;
    my $p = $self->SUPER::chat_payload(%a);
    # Azure expects deployment name in the model field, but we already have it in base_url
    return $p;
}

# Override streaming to hit the Azure endpoint with api-version
sub stream_chat {
    my ($self, %a) = @_;
    require JSON::PP;
    my $payload = $self->chat_payload(%a, stream => 1);
    my $url     = $self->{base_url} . '/chat/completions?api-version=' . $self->{api_version};
    my ($host, $port, $pathq) = _split_url($url);
    require IO::Socket::INET;
    my $sock = IO::Socket::INET->new(PeerAddr=>$host, PeerPort=>$port, Timeout=>$self->{timeout})
        or die "connect $host:$port: $!";
    my $body = JSON::PP->new->encode($payload);
    my %h = (%{ $self->headers }, 'Content-Length' => length($body), Host => $host);
    delete $h{'Accept'}; $h{Accept} = 'text/event-stream';
    my $req = "POST $pathq HTTP/1.1\r\n" . join('', map { "$_: $h{$_}\r\n" } sort keys %h) . "\r\n$body";
    print {$sock} $req or die "send: $!";
    my ($code, @lines);
    LINE: while (my $line = <$sock>) {
        if (!defined $code && $line =~ /^HTTP\/\S+\s+(\d+)/) { $code = $1; next; }
        last if defined $code && $line eq "\r\n";
        push @lines, $line if defined $code;
    }
    die "provider HTTP $code" unless defined $code && $code == 200;
    for my $l (@lines) {
        chomp $l; $l =~ s/\r$//;
        next unless $l =~ /^data:\s?(.*)$/;
        my $d = $1;
        last if $d eq '[DONE]';
        my $j = eval { JSON::PP->new->decode($d) };
        next unless ref $j eq 'HASH';
        my $delta = $j->{choices}[0]{delta} // {};
        my %ev;
        $ev{text}       = $delta->{content} if defined $delta->{content};
        $ev{tool_calls} = $delta->{tool_calls} if ref $delta->{tool_calls} eq 'ARRAY';
        $a{on_delta}->(\%ev) if keys %ev && $a{on_delta};
    }
    close $sock;
    return 1;
}

sub _split_url {
    my ($url) = @_;
    $url =~ s{^https?://}{};
    my ($hostport, $pathq) = split m{/}, $url, 2;
    $pathq //= '/';
    my ($host, $port) = split /:/, $hostport, 2;
    $port ||= 443;
    return ($host, $port, $pathq);
}

1;
