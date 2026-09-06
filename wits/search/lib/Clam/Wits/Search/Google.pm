# CLAM-WIT: name=Google
# CLAM-WIT: version=1.0.0
# CLAM-WIT: about=Web search provider: Google Custom Search API
# CLAM-WIT: usage=Input: { action: "search", query: "Perl tie IPC", limit: 5 } Output: { results: [{ content, url, title, provenance }] }
# CLAM-WIT: hint=search_google, Google, web search, Custom Search API
# CLAM-WIT: author=CLAM
# CLAM-WIT: license=Artistic-2.0
package Clam::Wits::Search::Google;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'search_google',
        description => 'Web search provider: Google Custom Search API',
        parameters  => {
            type       => 'object',
            properties => {
                action  => { type => 'string', description => 'Action: search, configure' },
                query   => { type => 'string', description => 'Search query' },
                limit   => { type => 'integer', description => 'Max results', default => 5 },
                api_key => { type => 'string', description => 'Google API key (for configure)' },
                cx      => { type => 'string', description => 'Custom Search Engine ID (for configure)' },
            },
            required => ['action'],
        },
        execute => sub {
            my ($args) = @_;
            my $action = $args->{action} // 'search';
            my %ctx = $args->{_ctx} ? %{$args->{_ctx}} : ();
            my $state = $ctx{state} // {};

            $state->{api_key} //= $ctx{config}{google_api_key} // '';
            $state->{cx} //= $ctx{config}{google_cx} // '';
            $state->{last_query} //= 0;
            $state->{min_interval} //= 1;

            if ($action eq 'configure') {
                $state->{api_key} = $args->{api_key} // $state->{api_key};
                $state->{cx} = $args->{cx} // $state->{cx};
                return { topic => 'search.google.configured', has_key => !!$state->{api_key}, has_cx => !!$state->{cx} };
            }

            if ($action eq 'search') {
                my $query = $args->{query} // '';
                my $limit = $args->{limit} // 5;
                return { error => "No query" } unless $query;
                return { error => "Not configured — need api_key and cx", topic => 'search.google.results', results => [] }
                    unless $state->{api_key} && $state->{cx};

                my $now = time();
                if ($now - $state->{last_query} < $state->{min_interval}) {
                    return { topic => 'search.google.results', results => [], error => "Rate limited" };
                }
                $state->{last_query} = $now;

                my $encoded = $query;
                $encoded =~ s/ /+/g;
                $encoded =~ s/([^A-Za-z0-9])/sprintf("%%%02X", ord($1))/ge;
                my $url = "https://www.googleapis.com/customsearch/v1?key=$state->{api_key}&cx=$state->{cx}&q=$encoded&num=$limit";

                my $response = _fetch($url);
                return { topic => 'search.google.results', results => [] } unless $response;

                my $data = eval { JSON::XS::decode_json($response) };
                return { topic => 'search.google.results', results => [] } unless ref $data eq 'HASH';

                my @results;
                for my $item (@{$data->{items} // []}) {
                    push @results, {
                        content    => $item->{snippet} // '',
                        text       => $item->{snippet} // '',
                        title      => $item->{title} // '',
                        _provider  => 'google',
                        _weight    => 0.3,
                        _timestamp => time(),
                        _url       => $item->{link} // '',
                        _ref       => 'google:' . ($item->{displayLink} // ''),
                        _score     => 0.7,
                    };
                }

                return { topic => 'search.google.results', results => \@results };
            }

            return { error => "Unknown action: $action" };
        },
    );
}

sub _fetch {
    my ($url) = @_;
    if (eval { require HTTP::Tiny; 1 }) {
        my $http = HTTP::Tiny->new(timeout => 8, agent => 'CLAM/1.0');
        my $res = $http->get($url);
        return $res->{content} if $res->{success};
    } elsif (eval { require LWP::UserAgent; 1 }) {
        my $http = LWP::UserAgent->new(timeout => 8, agent => 'CLAM/1.0');
        my $res = $http->get($url);
        return $res->decoded_content if $res->is_success;
    }
    return undef;
}

1;
