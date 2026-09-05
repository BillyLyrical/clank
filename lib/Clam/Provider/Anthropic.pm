package Clam::Provider::Anthropic;
use strict; use warnings;
use parent 'Clam::Provider';
# Anthropic Messages API — different format from OpenAI.
# POST /v1/messages, auth via x-api-key + anthropic-version header.
# System prompt is a top-level field, not a message.
# Tool calls use content blocks: {type:"tool_use", id, name, input}.
# Tool results use content blocks: {type:"tool_result", tool_use_id, content}.

my $ANTHROPIC_VERSION = '2023-06-01';

sub new {
    my ($c, %o) = @_;
    $o{base_url} //= 'https://api.anthropic.com';
    my $self = $c->SUPER::new(%o);
    $self->{max_tokens} //= 8192;  # Anthropic requires max_tokens
    return $self;
}

sub headers {
    my ($self) = @_;
    my %h = (
        'Content-Type'      => 'application/json',
        'x-api-key'         => $self->{api_key} // '',
        'anthropic-version' => $ANTHROPIC_VERSION,
    );
    return \%h;
}

# Transform internal messages to Anthropic format.
# Extract system prompt from messages, convert tool calls/results to content blocks.
sub chat_payload {
    my ($self, %a) = @_;
    my @msgs;
    my $system = '';

    for my $m (@{ $a{messages} // [] }) {
        my $role    = $m->{role};
        my $content = $m->{content} // '';

        # System prompts become the top-level system field
        if ($role eq 'system') {
            $system = ref $content eq 'ARRAY' ? join("\n", map { $_->{text} // $_ } @$content) : $content;
            next;
        }

        # Convert OpenAI-style tool_call messages to Anthropic content blocks
        if ($role eq 'assistant' && ref $content eq 'ARRAY') {
            my @blocks;
            for my $block (@$content) {
                if ($block->{type} eq 'text') {
                    push @blocks, { type => 'text', text => $block->{text} };
                } elsif ($block->{type} eq 'tool_use') {
                    push @blocks, {
                        type  => 'tool_use',
                        id    => $block->{id},
                        name  => $block->{name},
                        input => $block->{arguments} // $block->{input} // {},
                    };
                }
            }
            push @msgs, { role => 'assistant', content => \@blocks } if @blocks;
            next;
        }

        # Convert OpenAI-style tool result messages to Anthropic content blocks
        if ($role eq 'tool') {
            push @msgs, {
                role    => 'user',
                content => [{
                    type       => 'tool_result',
                    tool_use_id => $m->{tool_call_id} // $m->{id} // '',
                    content    => $content,
                }],
            };
            next;
        }

        # Regular messages — pass through
        push @msgs, { role => $role, content => $content };
    }

    my %p = (
        model      => $self->{model},
        messages   => \@msgs,
        max_tokens => $a{max_tokens} // $self->{max_tokens},
    );
    $p{system}  = $system if length $system;
    $p{tools}   = $self->_convert_tools($a{tools}) if $a{tools};
    $p{temperature} = $self->{temperature} if defined $self->{temperature};
    $p{stream}  = JSON::PP::true() if $a{stream};
    return \%p;
}

# Convert OpenAI tool schema to Anthropic format
sub _convert_tools {
    my ($self, $tools) = @_;
    return unless ref $tools eq 'ARRAY';
    return [map {
        {
            name        => $_->{function}{name} // $_->{name},
            description => $_->{function}{description} // $_->{description} // '',
            input_schema => $_->{function}{parameters} // $_->{parameters} // { type => 'object', properties => {} },
        }
    } @$tools];
}

sub post_json {
    my ($self, $path, $payload) = @_;
    require JSON::PP; require HTTP::Tiny;
    my $url  = $self->{base_url} . $path;
    my $http = HTTP::Tiny->new(timeout => $self->{timeout});
    my $res  = $http->request('POST', $url, {
        headers => $self->headers,
        content => JSON::PP->new->utf8->encode($payload),
    });
    die "anthropic request failed: $res->{status} $res->{reason}\n" . substr($res->{content}//'',0,500)
        unless $res->{success};
    return JSON::PP->new->decode($res->{content});
}

# Streaming: Anthropic sends event types (message_start, content_block_delta, etc.)
# We need to parse these into the same {text, tool_calls} deltas the loop expects.
sub stream_chat {
    my ($self, %a) = @_;
    require JSON::PP;
    my $payload = $self->chat_payload(%a, stream => 1);
    my $url     = $self->{base_url} . '/v1/messages';
    my ($host, $port, $pathq) = _split_url($url);
    require IO::Socket::INET;
    my $sock = IO::Socket::INET->new(PeerAddr=>$host, PeerPort=>$port, Timeout=>$self->{timeout})
        or die "connect $host:$port: $!";
    my $body = JSON::PP->new->encode($payload);
    my %h = (%{ $self->headers }, 'Content-Length' => length($body), Host => $host);
    $h{Accept} = 'text/event-stream';
    my $req = "POST $pathq HTTP/1.1\r\n" . join('', map { "$_: $h{$_}\r\n" } sort keys %h) . "\r\n$body";
    print {$sock} $req or die "send: $!";

    # Parse HTTP response
    my $code;
    while (my $line = <$sock>) {
        if (!defined $code && $line =~ /^HTTP\/\S+\s+(\d+)/) { $code = $1; next; }
        last if defined $code && $line eq "\r\n";
    }
    die "anthropic HTTP $code" unless defined $code && $code == 200;

    # Track tool use blocks as they stream in
    my @tool_blocks;
    my $current_tool_id   = '';
    my $current_tool_name = '';
    my $in_tool_input     = 0;
    my $tool_input_json   = '';

    while (my $line = <$sock>) {
        chomp $line;
        $line =~ s/\r$//;
        next unless $line =~ /^data:\s?(.*)$/;
        my $d = $1;
        last if $d eq '[DONE]';

        my $j = eval { JSON::PP->new->decode($d) };
        next unless ref $j eq 'HASH';

        my $type = $j->{type} // '';
        my %ev;

        if ($type eq 'content_block_start') {
            my $block = $j->{content_block} // {};
            if (($block->{type} // '') eq 'tool_use') {
                $current_tool_id   = $block->{id}   // '';
                $current_tool_name = $block->{name} // '';
                $in_tool_input     = 1;
                $tool_input_json   = '';
            }
        }
        elsif ($type eq 'content_block_delta') {
            my $delta = $j->{delta} // {};
            my $dtype = $delta->{type} // '';
            if ($dtype eq 'text_delta') {
                $ev{text} = $delta->{text} // '';
            }
            elsif ($dtype eq 'input_json_delta') {
                $tool_input_json .= $delta->{partial_json} // '';
            }
        }
        elsif ($type eq 'content_block_stop') {
            if ($in_tool_input && length $current_tool_id) {
                my $input = eval { JSON::PP->new->decode($tool_input_json) } // {};
                push @tool_blocks, {
                    id        => $current_tool_id,
                    name      => $current_tool_name,
                    type      => 'function',
                    function  => {
                        name      => $current_tool_name,
                        arguments => $tool_input_json,
                    },
                };
            }
            $in_tool_input     = 0;
            $current_tool_id   = '';
            $current_tool_name = '';
            $tool_input_json   = '';
        }
        elsif ($type eq 'message_delta') {
            # Emit accumulated tool calls when the message is done
            if (@tool_blocks) {
                $ev{tool_calls} = [@tool_blocks];
                @tool_blocks = ();
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
