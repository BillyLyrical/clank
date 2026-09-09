# CLANK-WIT: name=Llm
# CLANK-WIT: version=1.0.0
# CLANK-WIT: about=LLM search provider: queries local LLM for analysis, summaries, answers
# CLANK-WIT: usage=Input: { action: "search", query: "explain Perl tie() for IPC", limit: 3 } Output: { results: [{ content, provenance }] }
# CLANK-WIT: hint=search_llm, LLM, local LLM, analysis, summaries, knowledge
# CLANK-WIT: author=Clank
# CLANK-WIT: license=Artistic-2.0
package Clank::Wits::Search::Llm;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'search_llm',
        description => 'LLM search provider: queries local LLM for analysis, summaries, answers',
        parameters  => {
            type       => 'object',
            properties => {
                action  => { type => 'string', description => 'Action: search, configure' },
                query   => { type => 'string', description => 'Search query' },
                limit   => { type => 'integer', description => 'Max results', default => 1 },
                context => { type => 'string', description => 'Additional context' },
                endpoint => { type => 'string', description => 'LLM endpoint (for configure)' },
                model   => { type => 'string', description => 'LLM model name (for configure)' },
            },
            required => ['action'],
        },
        execute => sub {
            my ($args) = @_;
            my $action = $args->{action} // 'search';
            my %ctx = $args->{_ctx} ? %{$args->{_ctx}} : ();
            my $state = $ctx{state} // {};

            $state->{endpoint} //= 'http://maniac:1234/v1/chat/completions';
            $state->{model} //= 'mimo-auto';
            $state->{last_query} //= 0;
            $state->{min_interval} //= 2;

            if ($action eq 'search') {
                my $query = $args->{query} // '';
                my $limit = $args->{limit} // 1;
                my $context = $args->{context} // '';
                return { error => "No query" } unless $query;

                my $now = time();
                my $wait = $state->{min_interval} - ($now - $state->{last_query});
                if ($wait > 0) {
                    return { topic => 'search.llm.results', results => [], error => "Rate limited, wait ${wait}s" };
                }
                $state->{last_query} = $now;

                my $prompt = "Answer this question concisely. Focus on facts, not opinions.\n\n$query";
                $prompt .= "\n\nContext: $context" if $context;

                my $answer = _query_llm($state->{endpoint}, $state->{model}, $prompt);
                return { topic => 'search.llm.results', results => [] } unless $answer;

                my @results = ({
                    content    => $answer,
                    text       => $answer,
                    title      => "LLM: $query",
                    _provider  => 'llm',
                    _weight    => 0.4,
                    _timestamp => time(),
                    _url       => '',
                    _ref       => "llm:$state->{model}",
                    _score     => 0.6,
                });

                return { topic => 'search.llm.results', results => \@results };
            }

            if ($action eq 'configure') {
                my $endpoint = $args->{endpoint} // '';
                my $model = $args->{model} // '';
                $state->{endpoint} = $endpoint if $endpoint;
                $state->{model} = $model if $model;
                return { topic => 'search.llm.configured', endpoint => $state->{endpoint}, model => $state->{model} };
            }

            return { error => "Unknown action: $action" };
        },
    );
}

sub _query_llm {
    my ($endpoint, $model, $prompt) = @_;
    require JSON::XS;
    my $payload = JSON::XS::encode_json({
        model    => $model,
        messages => [{ role => 'user', content => $prompt }],
        max_tokens => 500,
        temperature => 0.3,
    });

    my $response = '';
    if (eval { require HTTP::Tiny; 1 }) {
        my $http = HTTP::Tiny->new(timeout => 15, agent => "Clank/1.0");
        my $res = $http->post($endpoint, {
            content => $payload,
            headers => { 'Content-Type' => 'application/json' },
        });
        $response = $res->{content} if $res->{success};
    } elsif (eval { require LWP::UserAgent; 1 }) {
        my $http = LWP::UserAgent->new(timeout => 15, agent => "Clank/1.0");
        my $res = $http->post($endpoint, Content => $payload, 'Content-Type' => 'application/json');
        $response = $res->decoded_content if $res->is_success;
    }

    return undef unless $response;
    my $data = eval { JSON::XS::decode_json($response) };
    return undef unless ref $data eq 'HASH';
    return $data->{choices}[0]{message}{content} // undef;
}

1;
