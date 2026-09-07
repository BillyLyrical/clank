# CLAM-WIT: name=Yandex
# CLAM-WIT: version=1.0.0
# CLAM-WIT: about=Web search provider: Yandex XML Search API
# CLAM-WIT: usage=Input: { action: "search", query: "Perl tie IPC", limit: 5 } Output: { results: [{ content, url, title, provenance }] }
# CLAM-WIT: hint=search_yandex, Yandex, web search, Russian, Eastern European
# CLAM-WIT: author=CLAM
# CLAM-WIT: license=Artistic-2.0
package AI::Clam::Wits::Search::Yandex;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'search_yandex',
        description => 'Web search provider: Yandex XML Search API',
        parameters  => {
            type       => 'object',
            properties => {
                action  => { type => 'string', description => 'Action: search, configure' },
                query   => { type => 'string', description => 'Search query' },
                limit   => { type => 'integer', description => 'Max results', default => 5 },
                api_key => { type => 'string', description => 'Yandex API key (for configure)' },
            },
            required => ['action'],
        },
        execute => sub {
            my ($args) = @_;
            my $action = $args->{action} // 'search';
            my %ctx = $args->{_ctx} ? %{$args->{_ctx}} : ();
            my $state = $ctx{state} // {};

            $state->{api_key} //= $ctx{config}{yandex_api_key} // '';
            $state->{last_query} //= 0;
            $state->{min_interval} //= 1;

            if ($action eq 'configure') {
                $state->{api_key} = $args->{api_key} // $state->{api_key};
                return { topic => 'search.yandex.configured', has_key => !!$state->{api_key} };
            }

            if ($action eq 'search') {
                my $query = $args->{query} // '';
                my $limit = $args->{limit} // 5;
                return { error => "No query" } unless $query;
                return { error => "Not configured — need api_key", topic => 'search.yandex.results', results => [] }
                    unless $state->{api_key};

                my $now = time();
                if ($now - $state->{last_query} < $state->{min_interval}) {
                    return { topic => 'search.yandex.results', results => [], error => "Rate limited" };
                }
                $state->{last_query} = $now;

                my $encoded = $query;
                $encoded =~ s/ /+/g;
                $encoded =~ s/([^A-Za-z0-9])/sprintf("%%%02X", ord($1))/ge;
                my $url = "https://yandex.com/search/xml?query=$encoded&lr=213&numdoc=$limit&apikey=$state->{api_key}";

                my $response = _fetch($url);
                return { topic => 'search.yandex.results', results => [] } unless $response;

                my @results;
                while ($response =~ /<url>(.*?)<\/url>.*?<title>(.*?)<\/title>.*?<headline>(.*?)<\/headline>/gs) {
                    my ($url, $title, $snippet) = ($1, $2, $3);
                    s/&amp;/&/g for $url, $title, $snippet;
                    s/&lt;/</g for $url, $title, $snippet;
                    s/&gt;/>/g for $url, $title, $snippet;
                    s/&quot;/"/g for $url, $title, $snippet;

                    push @results, {
                        content    => $snippet,
                        text       => $snippet,
                        title      => $title,
                        _provider  => 'yandex',
                        _weight    => 0.3,
                        _timestamp => time(),
                        _url       => $url,
                        _ref       => "yandex:$url",
                        _score     => 0.6,
                    };
                    last if @results >= $limit;
                }

                return { topic => 'search.yandex.results', results => \@results };
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
