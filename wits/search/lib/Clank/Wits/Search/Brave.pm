# CLANK-WIT: name=Brave
# CLANK-WIT: version=1.0.0
# CLANK-WIT: about=Web search provider: Brave Search API
# CLANK-WIT: usage=Input: { action: "search", query: "Perl tie IPC", limit: 5 } Output: { results: [{ content, url, title, provenance }] }
# CLANK-WIT: hint=search_brave, Brave, privacy, web search, no tracking
# CLANK-WIT: author=Clank
# CLANK-WIT: license=Artistic-2.0
package Clank::Wits::Search::Brave;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'search_brave',
        description => 'Web search provider: Brave Search API',
        parameters  => {
            type       => 'object',
            properties => {
                action  => { type => 'string', description => 'Action: search, configure' },
                query   => { type => 'string', description => 'Search query' },
                limit   => { type => 'integer', description => 'Max results', default => 5 },
                api_key => { type => 'string', description => 'Brave API key (for configure)' },
            },
            required => ['action'],
        },
        execute => sub {
            my ($args) = @_;
            my $action = $args->{action} // 'search';
            my %ctx = $args->{_ctx} ? %{$args->{_ctx}} : ();
            my $state = $ctx{state} // {};

            $state->{api_key} //= $ctx{config}{brave_api_key} // '';
            $state->{last_query} //= 0;
            $state->{min_interval} //= 1;

            if ($action eq 'configure') {
                $state->{api_key} = $args->{api_key} // $state->{api_key};
                return { topic => 'search.brave.configured', has_key => !!$state->{api_key} };
            }

            if ($action eq 'search') {
                my $query = $args->{query} // '';
                my $limit = $args->{limit} // 5;
                return { error => "No query" } unless $query;
                return { error => "Not configured — need api_key", topic => 'search.brave.results', results => [] }
                    unless $state->{api_key};

                my $now = time();
                if ($now - $state->{last_query} < $state->{min_interval}) {
                    return { topic => 'search.brave.results', results => [], error => "Rate limited" };
                }
                $state->{last_query} = $now;

                my $encoded = $query;
                $encoded =~ s/ /+/g;
                $encoded =~ s/([^A-Za-z0-9])/sprintf("%%%02X", ord($1))/ge;
                my $url = "https://api.search.brave.com/res/v1/web/search?q=$encoded&count=$limit";

                my $response = _fetch($url, $state->{api_key});
                return { topic => 'search.brave.results', results => [] } unless $response;

                my $data = eval { JSON::XS::decode_json($response) };
                return { topic => 'search.brave.results', results => [] } unless ref $data eq 'HASH';

                my @results;
                for my $item (@{$data->{web}{results} // []}) {
                    push @results, {
                        content    => $item->{description} // '',
                        text       => $item->{description} // '',
                        title      => $item->{title} // '',
                        _provider  => 'brave',
                        _weight    => 0.35,
                        _timestamp => time(),
                        _url       => $item->{url} // '',
                        _ref       => 'brave:' . ($item->{meta_url}{hostname} // ''),
                        _score     => 0.7,
                    };
                }

                return { topic => 'search.brave.results', results => \@results };
            }

            return { error => "Unknown action: $action" };
        },
    );
}

sub _fetch {
    my ($url, $key) = @_;
    if (eval { require HTTP::Tiny; 1 }) {
        my $http = HTTP::Tiny->new(timeout => 8, agent => "Clank/1.0");
        my $res = $http->get($url, { headers => { accept => 'application/json', 'X-Subscription-Token' => $key } });
        return $res->{content} if $res->{success};
    } elsif (eval { require LWP::UserAgent; 1 }) {
        my $http = LWP::UserAgent->new(timeout => 8, agent => "Clank/1.0");
        my $res = $http->get($url, Authorization => "Bearer $key", Accept => 'application/json');
        return $res->decoded_content if $res->is_success;
    }
    return undef;
}

1;
