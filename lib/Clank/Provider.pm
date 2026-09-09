package Clank::Provider;
use strict; use warnings;
# Base class for LLM providers (OpenAI-compatible chat completions).
# Config precedence: CLI flags > env (CLANK_PROVIDER/CLANK_MODEL/CLANK_BASE_URL/CLANK_API_KEY)
#   > ~/.clank/config.json > defaults. API keys are never written to DB or logs.

sub new {
    my ($class, %o) = @_;
    my $cfg_file = "$ENV{HOME}/.clank/config.json";
    my %file_cfg;
    if (-f $cfg_file) {
        require JSON::PP;
        my $j = eval { JSON::PP->new->decode(slurp_json($cfg_file)) };
        %file_cfg = ref $j eq 'HASH' ? %$j : ();
    }
    my %c = (
        name      => $o{name}       // $ENV{CLANK_PROVIDER} // $file_cfg{provider} // 'lmstudio',
        model     => $o{model}      // $ENV{CLANK_MODEL}    // $file_cfg{model}      // 'local-model',
        base_url  => $o{base_url}   // $ENV{CLANK_BASE_URL} // $file_cfg{base_url}   // 'http://localhost:1234/v1',
        api_key   => $o{api_key}    // $ENV{CLANK_API_KEY}  // $file_cfg{api_key},
        temperature => $o{temperature} // $file_cfg{temperature},
        max_tokens  => $o{max_tokens}  // $file_cfg{max_tokens},
        timeout     => $o{timeout}     // 300,
    );
    return bless \%c, $class;
}

sub slurp_json { my ($f)=@_; open my $fh,'<:encoding(UTF-8)',$f or die "open $f: $!"; local $/; <$fh>; }

# --- API key privacy -------------------------------------------------------
sub api_key_redacted { my ($s)=@_; return '(none)' unless defined $s->{api_key} && length $s->{api_key};
    my $k = $s->{api_key}; return '***' if length($k) <= 4; return substr($k,0,2).'***'.substr($k,-2); }

sub log_safe { # stringify config without leaking keys
    my ($s)=@_;
    return sprintf("provider=%s model=%s base_url=%s key=%s", $s->{name},$s->{model},$s->{base_url},$s->api_key_redacted);
}

# --- request building ------------------------------------------------------
sub chat_payload {
    my ($self, %a) = @_;
    my %p = (
        model       => $self->{model},
        messages    => $a{messages},          # arrayref of {role, content} or pi-style blocks
        stream      => 0 + ($a{stream} // 0),
    );
    $p{tools} = $a{tools} if ref $a{tools} eq 'ARRAY' && @{$a{tools}};
    $p{tool_choice} = $a{tool_choice} if defined $a{tool_choice};
    $p{temperature} = $self->{temperature} if defined $self->{temperature};
    $p{max_tokens}  = $a{max_tokens} // $self->{max_tokens} if defined ($a{max_tokens} // $self->{max_tokens});
    %p = grep { defined $_[1] } %p;
    return \%p;
}

sub headers {
    my ($self) = @_;
    my %h = ('Content-Type' => 'application/json', Accept => 'text/event-stream, application/json');
    $h{Authorization} = "Bearer $self->{api_key}" if defined $self->{api_key} && length $self->{api_key};
    return \%h;
}

# --- transport -------------------------------------------------------------
sub post_json { # returns decoded body (non-streaming)
    my ($self, $path, $payload) = @_;
    require JSON::PP; require HTTP::Tiny;
    my $url  = $self->{base_url} . $path;
    my $http = HTTP::Tiny->new(timeout => $self->{timeout});
    my $res  = $http->request('POST', $url, { headers => $self->headers, content => JSON::PP->new->utf8->encode($payload) });
    die "provider request failed: $res->{status} $res->{reason}\n" . substr($res->{content}//'',0,500) unless $res->{success};
    return JSON::PP->new->decode($res->{content});
}

# Streaming SSE via raw socket. Calls $on_delta({text=>..., tool_calls=>...}) per chunk.
sub stream_chat {
    my ($self, %a) = @_;
    require JSON::PP;
    my $payload = $self->chat_payload(%a, stream => 1);
    my $url     = $self->{base_url} . '/chat/completions';
    my ($host, $port, $pathq) = _split_url($url);
    require IO::Socket::INET;
    my $sock = IO::Socket::INET->new(PeerAddr=>$host, PeerPort=>$port, Timeout=>$self->{timeout})
        or die "connect $host:$port: $!";
    my $body = JSON::PP->new->encode($payload);
    my %h = (%{ $self->headers }, 'Content-Length' => length($body), Host => $host);
    delete $h{'Accept'}; $h{Accept} = 'text/event-stream';
    my $req = "POST $pathq HTTP/1.1\r\n" . join('', map { "$_: $h{$_}\r\n" } sort keys %h) . "\r\n$body";
    print {$sock} $req or die "send: $!";
    my ($code, %resp_h, @lines);
    LINE: while (my $line = <$sock>) {
        if (!defined $code && $line =~ /^HTTP\/\S+\s+(\d+)/) { $code = $1; next; }
        last if defined $code && $line eq "\r\n";
        push @lines, $line if defined $code;
    }
    die "provider HTTP $code" unless defined $code && $code == 200;
    my ($buf) = '';
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
    $port ||= 80;
    return ($host, $port, $pathq);
}

1;
