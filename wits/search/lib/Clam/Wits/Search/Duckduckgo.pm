# CLAM-WIT: name=Duckduckgo
# CLAM-WIT: version=1.0.0
# CLAM-WIT: about=Web search provider: DuckDuckGo instant answers and results
# CLAM-WIT: usage=Input: { action: "search", query: "Perl tie IPC", limit: 5 } Output: { results: [{ content, url, title, provenance }] }
# CLAM-WIT: hint=search_duckduckgo, DuckDuckGo, web search, instant answers, no API key
# CLAM-WIT: author=CLAM
# CLAM-WIT: license=Artistic-2.0
package Clam::Wits::Search::Duckduckgo;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'search_duckduckgo',
        description => 'Web search provider: DuckDuckGo instant answers and results',
        parameters  => {
            type       => 'object',
            properties => {
                action => { type => 'string', description => 'Action: search' },
                query  => { type => 'string', description => 'Search query' },
                limit  => { type => 'integer', description => 'Max results', default => 5 },
            },
            required => ['action', 'query'],
        },
        execute => sub {
            my ($args) = @_;
            my $action = $args->{action} // 'search';

            if ($action eq 'search') {
                my $query = $args->{query} // '';
                my $limit = $args->{limit} // 5;
                return { error => "No query" } unless $query;

                my @results;

                my $encoded = $query;
                $encoded =~ s/ /+/g;
                $encoded =~ s/([^A-Za-z0-9])/sprintf("%%%02X", ord($1))/ge;

                my $url = "https://api.duckduckgo.com/?q=$encoded&format=json&no_html=1&skip_disambig=1";
                my $ua = 'CLAM/1.0 (search provider)';
                my $response = '';
                if (eval { require LWP::UserAgent; 1 }) {
                    my $http = LWP::UserAgent->new(timeout => 5, agent => $ua);
                    my $res = $http->get($url);
                    $response = $res->decoded_content if $res->is_success;
                } elsif (eval { require HTTP::Tiny; 1 }) {
                    my $http = HTTP::Tiny->new(timeout => 5, agent => $ua);
                    my $res = $http->get($url);
                    $response = $res->{content} if $res->{success};
                }

                return { topic => 'search.ddg.results', results => [] } unless $response;

                my $data = eval { JSON::XS::decode_json($response) };
                return { topic => 'search.ddg.results', results => [] } unless ref $data eq 'HASH';

                if ($data->{Abstract} && length($data->{Abstract}) > 20) {
                    push @results, {
                        content    => $data->{Abstract},
                        text       => $data->{Abstract},
                        title      => $data->{Heading} // '',
                        _provider  => 'duckduckgo',
                        _weight    => 0.3,
                        _timestamp => time(),
                        _url       => $data->{AbstractURL} // '',
                        _ref       => $data->{AbstractSource} // 'duckduckgo',
                        _score     => 0.8,
                    };
                }

                if (ref $data->{RelatedTopics} eq 'ARRAY') {
                    for my $t (@{$data->{RelatedTopics}}[0..($limit > 4 ? 4 : $limit-1)]) {
                        next unless ref $t eq 'HASH';
                        my $text = $t->{Text} // '';
                        next unless length($text) > 10;
                        push @results, {
                            content    => $text,
                            text       => $text,
                            title      => $t->{Text} // '',
                            _provider  => 'duckduckgo',
                            _weight    => 0.3,
                            _timestamp => time(),
                            _url       => $t->{FirstURL} // '',
                            _ref       => 'duckduckgo:related',
                            _score     => 0.5,
                        };
                    }
                }

                if ($data->{Answer} && length($data->{Answer}) > 5) {
                    unshift @results, {
                        content    => $data->{Answer},
                        text       => $data->{Answer},
                        title      => 'Answer',
                        _provider  => 'duckduckgo',
                        _weight    => 0.3,
                        _timestamp => time(),
                        _url       => $data->{AnswerURL} // '',
                        _ref       => 'duckduckgo:answer',
                        _score     => 0.9,
                    };
                }

                @results = @results[0..$limit-1] if @results > $limit;
                return { topic => 'search.ddg.results', results => \@results };
            }

            return { error => "Unknown action: $action" };
        },
    );
}

1;
