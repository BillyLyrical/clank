package Clank::Providers;
use strict; use warnings;
# Provider registry + factory. API keys are never logged or persisted here.

my %KNOWN = (
    lmstudio        => 'Clank::Provider::LMStudio',
    'openai-compat' => 'Clank::Provider::OpenAICompat',
    ollama          => 'Clank::Provider::Ollama',
    openai          => 'Clank::Provider::OpenAI',
    anthropic       => 'Clank::Provider::Anthropic',
    gemini          => 'Clank::Provider::Gemini',
    azure           => 'Clank::Provider::Azure',
    mock            => 'Clank::Provider::Mock',
);

sub known { sort keys %KNOWN; }

# Class method: Clank::Providers->create(%o). (Written as a plain function it
# swallowed the class name and silently dropped every option — --provider etc.)
sub create {
    my ($class, %o) = @_;
    my $name  = lc($o{name} // 'lmstudio');
    my $impl  = $KNOWN{$name} or die "unknown provider '$name' (known: ".join(', ', known()).")\n";
    (my $file = $impl) =~ s{::}{/}g;
    require "$file.pm";
    return $impl->new(%o);
}

# GET {base_url}/models — used by `clank providers test`. Returns arrayref of ids.
sub probe_models {
    my ($provider) = @_;
    require HTTP::Tiny; require JSON::PP;
    (my $url = $provider->{base_url}) =~ s{/v1/?$}{/v1/models};
    $url .= '/models' unless $url =~ /\/models$/;
    my %h = (Accept => 'application/json');
    $h{Authorization} = "Bearer $provider->{api_key}" if defined $provider->{api_key} && length $provider->{api_key};
    my $res = HTTP::Tiny->new(timeout => 10)->request('GET', $url, { headers => \%h });
    die "probe failed: $res->{status} $res->{reason}\n" unless $res->{success};
    my $j = eval { JSON::PP->new->decode($res->{content}) } // {};
    return [ map { $_->{id} } grep { ref $_ eq 'HASH' && defined $_->{id} } @{ $j->{data} // [] } ];
}

1;
