package AI::Clam::Provider::Gemini;
use strict; use warnings;
use parent 'AI::Clam::Provider';
# Google Generative AI (Gemini) — different API format.
# POST /v1beta/models/{model}:generateContent?key=...
# Messages use 'contents' with 'parts' arrays.
# Tool calls: {functionCall: {name, args}} parts.
# Tool results: {functionResponse: {name, response}} parts.
# Streaming: :streamGenerateContent, returns JSON array chunks.

sub new {
    my ($c, %o) = @_;
    $o{base_url} //= 'https://generativelanguage.googleapis.com';
    my $self = $c->SUPER::new(%o);
    $self->{max_tokens} //= 8192;
    return $self;
}

# Gemini puts the API key in the URL query string
sub _api_url {
    my ($self, $action) = @_;
    my $model = $self->{model};
    my $key   = $self->{api_key} // '';
    return "$self->{base_url}/v1beta/models/$model:$action?key=$key";
}

sub headers {
    my ($self) = @_;
    return { 'Content-Type' => 'application/json' };
}

# Convert internal messages to Gemini 'contents' format
sub chat_payload {
    my ($self, %a) = @_;
    my @contents;
    my $system = '';

    for my $m (@{ $a{messages} // [] }) {
        my $role    = $m->{role};
        my $content = $m->{content} // '';

        if ($role eq 'system') {
            $system = ref $content eq 'ARRAY' ? join("\n", map { $_->{text} // $_ } @$content) : $content;
            next;
        }

        # Map roles: assistant -> model (Gemini uses 'model' not 'assistant')
        my $g_role = $role eq 'assistant' ? 'model' : 'user';

        # Convert content to parts
        my @parts;
        if (ref $content eq 'ARRAY') {
            for my $block (@$content) {
                if (($block->{type} // '') eq 'text') {
                    push @parts, { text => $block->{text} };
                } elsif (($block->{type} // '') eq 'tool_use') {
                    push @parts, {
                        functionCall => {
                            name => $block->{name},
                            args => $block->{arguments} // $block->{input} // {},
                        },
                    };
                } elsif (($block->{type} // '') eq 'tool_result') {
                    my $result = ref $block->{content} eq 'JSON' ? $block->{content} : $block->{content};
                    push @parts, {
                        functionResponse => {
                            name     => $block->{name} // '',
                            response => { result => $result },
                        },
                    };
                }
            }
        } elsif (length $content) {
            push @parts, { text => $content };
        }

        # Handle tool result messages (role='tool' in OpenAI format)
        if ($role eq 'tool') {
            push @contents, {
                role  => 'user',
                parts => [{
                    functionResponse => {
                        name     => $m->{tool_call_id} // $m->{name} // '',
                        response => { result => $content },
                    },
                }],
            };
            next;
        }

        push @contents, { role => $g_role, parts => \@parts } if @parts;
    }

    my %p = ( contents => \@contents );
    $p{systemInstruction} = { parts => [{ text => $system }] } if length $system;
    $p{generationConfig} = {};
    $p{generationConfig}{temperature} = $self->{temperature} if defined $self->{temperature};
    $p{generationConfig}{maxOutputTokens} = $a{max_tokens} // $self->{max_tokens};
    $p{tools} = $self->_convert_tools($a{tools}) if $a{tools};
    return \%p;
}

# Convert OpenAI tool schema to Gemini format
sub _convert_tools {
    my ($self, $tools) = @_;
    return unless ref $tools eq 'ARRAY';
    return [{
        functionDeclarations => [map {
            {
                name        => $_->{function}{name} // $_->{name},
                description => $_->{function}{description} // $_->{description} // '',
                parameters  => $_->{function}{parameters} // $_->{parameters} // { type => 'OBJECT', properties => {} },
            }
        } @$tools],
    }];
}

sub post_json {
    my ($self, $path, $payload) = @_;
    # path is ignored — we use _api_url
    require JSON::PP; require HTTP::Tiny;
    my $url  = $self->_api_url('generateContent');
    my $http = HTTP::Tiny->new(timeout => $self->{timeout});
    my $res  = $http->request('POST', $url, {
        headers => $self->headers,
        content => JSON::PP->new->utf8->encode($payload),
    });
    die "gemini request failed: $res->{status} $res->{reason}\n" . substr($res->{content}//'',0,500)
        unless $res->{success};
    return JSON::PP->new->decode($res->{content});
}

# Streaming: Gemini uses :streamGenerateContent?alt=sse for SSE format
sub stream_chat {
    my ($self, %a) = @_;
    require JSON::PP;
    my $payload = $self->chat_payload(%a, stream => 1);
    my $url     = $self->_api_url('streamGenerateContent') . '&alt=sse';
    my ($host, $port, $pathq) = _split_url($url);
    require IO::Socket::INET;
    my $sock = IO::Socket::INET->new(PeerAddr=>$host, PeerPort=>$port, Timeout=>$self->{timeout})
        or die "connect $host:$port: $!";
    my $body = JSON::PP->new->encode($payload);
    my %h = ('Content-Type' => 'application/json', 'Content-Length' => length($body),
             Host => $host, Accept => 'text/event-stream');
    my $req = "POST $pathq HTTP/1.1\r\n" . join('', map { "$_: $h{$_}\r\n" } sort keys %h) . "\r\n$body";
    print {$sock} $req or die "send: $!";

    my $code;
    while (my $line = <$sock>) {
        if (!defined $code && $line =~ /^HTTP\/\S+\s+(\d+)/) { $code = $1; next; }
        last if defined $code && $line eq "\r\n";
    }
    die "gemini HTTP $code" unless defined $code && $code == 200;

    while (my $line = <$sock>) {
        chomp $line;
        $line =~ s/\r$//;
        next unless $line =~ /^data:\s?(.*)$/;
        my $d = $1;
        last if $d eq '[DONE]';

        my $j = eval { JSON::PP->new->decode($d) };
        next unless ref $j eq 'HASH';

        # Gemini streaming response has candidates[0].content.parts
        my $candidate = $j->{candidates}[0] // {};
        my $content   = $candidate->{content} // {};
        my $parts     = $content->{parts} // [];
        my %ev;

        for my $part (@$parts) {
            if (defined $part->{text}) {
                $ev{text} .= $part->{text};
            }
            if (ref $part->{functionCall} eq 'HASH') {
                my $fc = $part->{functionCall};
                push @{ $ev{tool_calls} }, {
                    id       => 'call_' . unpack('H*', pack('N', rand(2**32))),
                    type     => 'function',
                    function => {
                        name      => $fc->{name},
                        arguments => JSON::PP->new->encode($fc->{args} // {}),
                    },
                };
            }
        }

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
