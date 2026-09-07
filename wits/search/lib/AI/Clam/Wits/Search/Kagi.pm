# CLAM-WIT: name=Kagi
# CLAM-WIT: version=1.0.0
# CLAM-WIT: about=Web search provider: Kagi Search API (paid, no ads)
# CLAM-WIT: usage=Input: { action: "search", query: "Perl tie IPC", limit: 5 } Output: { results: [{ content, url, title, provenance }] }
# CLAM-WIT: hint=search_kagi, Kagi, web search, paid search, no ads
# CLAM-WIT: author=CLAM
# CLAM-WIT: license=Artistic-2.0
package AI::Clam::Wits::Search::Kagi;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'search_kagi',
        description => 'Web search provider: Kagi Search API (paid, no ads)',
        parameters  => {
            type       => 'object',
            properties => {
                action  => { type => 'string', description => 'Action: search, configure' },
                query   => { type => 'string', description => 'Search query' },
                limit   => { type => 'integer', description => 'Max results', default => 5 },
                api_key => { type => 'string', description => 'Kagi API key (for configure)' },
            },
            required => ['action'],
        },
        execute => sub {
            my ($args) = @_;
            my $action = $args->{action} // 'search';
            my %ctx = $args->{_ctx} ? %{$args->{_ctx}} : ();
            my $state = $ctx{state} // {};

            $state->{api_key} //= $ctx{config}{kagi_api_key} // '';
            $state->{last_query} //= 0;
            $state->{min_interval} //= 1;

            if ($action eq 'configure') {
                $state->{api_key} = $args->{api_key} // $state->{api_key};
                return { topic => 'search.kagi.configured', has_key => !!$state->{api_key} };
            }

            if ($action eq 'search') {
                my $query = $args->{query} // '';
                my $limit = $args->{limit} // 5;
                return { error => "No query" } unless $query;
                return { error => "Not configured — need api_key", topic => 'search.kagi.results', results => [] }
                    unless $state->{api_key};

                my $now = time();
                if ($now - $state->{last_query} < $state->{min_interval}) {
                    return { topic => 'search.kagi.results', results => [], error => "Rate limited" };
                }
                $state->{last_query} = $now;

                my $payload = JSON::XS::encode_json({ query => $query, limit => $limit });
                my $response = _post("https://api.kagi.com/v0/search", $state->{api_key}, $payload);
                return { topic => 'search.kagi.results', results => [] } unless $response;

                my $data = eval { JSON::XS::decode_json($response) };
                return { topic => 'search.kagi.results', results => [] } unless ref $data eq 'HASH';

                my @results;
                for my $item (@{$data->{data} // []}) {
                    next if ($item->{t} // '') eq 'infobox';
                    push @results, {
                        content    => $item->{snippet} // $item->{description} // '',
                        text       => $item->{snippet} // $item->{description} // '',
                        title      => $item->{title} // '',
                        _provider  => 'kagi',
                        _weight    => 0.4,
                        _timestamp => time(),
                        _url       => $item->{url} // '',
                        _ref       => 'kagi:' . ($item->{host} // ''),
                        _score     => 0.75,
                    };
                }

                return { topic => 'search.kagi.results', results => \@results };
            }

            return { error => "Unknown action: $action" };
        },
    );
}

sub _post {
    my ($url, $key, $body) = @_;
    if (eval { require HTTP::Tiny; 1 }) {
        my $http = HTTP::Tiny->new(timeout => 8, agent => 'CLAM/1.0');
        my $res = $http->post($url, {
            content => $body,
            headers => { 'Content-Type' => 'application/json', Authorization => "Bot $key" },
        });
        return $res->{content} if $res->{success};
    } elsif (eval { require LWP::UserAgent; 1 }) {
        my $http = LWP::UserAgent->new(timeout => 8, agent => 'CLAM/1.0');
        my $res = $http->post($url, Content => $body, 'Content-Type' => 'application/json', Authorization => "Bot $key");
        return $res->decoded_content if $res->is_success;
    }
    return undef;
}

1;
