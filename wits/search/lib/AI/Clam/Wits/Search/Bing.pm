# CLAM-WIT: name=Bing
# CLAM-WIT: version=1.0.0
# CLAM-WIT: about=Web search provider: Bing Web Search API
# CLAM-WIT: usage=Input: { action: "search", query: "Perl tie IPC", limit: 5 } Output: { results: [{ content, url, title, provenance }] }
# CLAM-WIT: hint=search_bing, Bing, Microsoft, web search
# CLAM-WIT: author=CLAM
# CLAM-WIT: license=Artistic-2.0
package AI::Clam::Wits::Search::Bing;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'search_bing',
        description => 'Web search provider: Bing Web Search API',
        parameters  => {
            type       => 'object',
            properties => {
                action  => { type => 'string', description => 'Action: search, configure' },
                query   => { type => 'string', description => 'Search query' },
                limit   => { type => 'integer', description => 'Max results', default => 5 },
                api_key => { type => 'string', description => 'Azure API key (for configure)' },
            },
            required => ['action'],
        },
        execute => sub {
            my ($args) = @_;
            my $action = $args->{action} // 'search';
            my %ctx = $args->{_ctx} ? %{$args->{_ctx}} : ();
            my $state = $ctx{state} // {};

            $state->{api_key} //= $ctx{config}{bing_api_key} // '';
            $state->{last_query} //= 0;
            $state->{min_interval} //= 1;

            if ($action eq 'configure') {
                $state->{api_key} = $args->{api_key} // $state->{api_key};
                return { topic => 'search.bing.configured', has_key => !!$state->{api_key} };
            }

            if ($action eq 'search') {
                my $query = $args->{query} // '';
                my $limit = $args->{limit} // 5;
                return { error => "No query" } unless $query;
                return { error => "Not configured — need api_key", topic => 'search.bing.results', results => [] }
                    unless $state->{api_key};

                my $now = time();
                if ($now - $state->{last_query} < $state->{min_interval}) {
                    return { topic => 'search.bing.results', results => [], error => "Rate limited" };
                }
                $state->{last_query} = $now;

                my $encoded = $query;
                $encoded =~ s/ /+/g;
                $encoded =~ s/([^A-Za-z0-9])/sprintf("%%%02X", ord($1))/ge;
                my $url = "https://api.bing.microsoft.com/v7.0/search?q=$encoded&count=$limit";

                my $response = _fetch($url, $state->{api_key});
                return { topic => 'search.bing.results', results => [] } unless $response;

                my $data = eval { JSON::XS::decode_json($response) };
                return { topic => 'search.bing.results', results => [] } unless ref $data eq 'HASH';

                my @results;
                for my $item (@{$data->{webPages}{value} // []}) {
                    push @results, {
                        content    => $item->{snippet} // '',
                        text       => $item->{snippet} // '',
                        title      => $item->{name} // '',
                        _provider  => 'bing',
                        _weight    => 0.3,
                        _timestamp => time(),
                        _url       => $item->{url} // '',
                        _ref       => 'bing:' . ($item->{displayUrl} // ''),
                        _score     => 0.65,
                    };
                }

                return { topic => 'search.bing.results', results => \@results };
            }

            return { error => "Unknown action: $action" };
        },
    );
}

sub _fetch {
    my ($url, $key) = @_;
    if (eval { require HTTP::Tiny; 1 }) {
        my $http = HTTP::Tiny->new(timeout => 8, agent => 'CLAM/1.0');
        my $res = $http->get($url, { headers => { 'Ocp-Apim-Subscription-Key' => $key } });
        return $res->{content} if $res->{success};
    } elsif (eval { require LWP::UserAgent; 1 }) {
        my $http = LWP::UserAgent->new(timeout => 8, agent => 'CLAM/1.0');
        my $res = $http->get($url, 'Ocp-Apim-Subscription-Key' => $key);
        return $res->decoded_content if $res->is_success;
    }
    return undef;
}

1;
