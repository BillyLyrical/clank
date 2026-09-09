# CLANK-WIT: name=Delete
# CLANK-WIT: version=1.0.0
# CLANK-WIT: about=HTTP DELETE request
# CLANK-WIT: usage=Input: { url: "https://api.example.com/data/1" } Output: { status: 204, content: "" }
# CLANK-WIT: hint=http delete request, remove, api call, rest
# CLANK-WIT: author=Clank
# CLANK-WIT: license=Artistic-2.0
package Clank::Wits::Web::Delete;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;
    $api->register_tool(
        name        => 'web_delete',
        description => 'HTTP DELETE request',
        parameters  => {
            type       => 'object',
            properties => {
                url     => { type => 'string', description => 'URL to delete' },
                timeout => { type => 'integer', description => 'Timeout in seconds', default => 30 },
                headers => { type => 'object', description => 'Additional headers' },
            },
            required => ['url'],
        },
        execute => sub {
            my ($args) = @_;
            my $url     = $args->{url}     // '';
            my $timeout = $args->{timeout} // 30;
            my $headers = $args->{headers} // {};

            return { error => "No URL provided" } unless $url;
            return { error => "URL must start with http" } unless $url =~ m{^https?://};

            eval { require HTTP::Tiny; 1 } or return { error => "HTTP::Tiny not installed" };

            my $http = HTTP::Tiny->new(
                timeout => $timeout,
                agent   => 'Clank/1.0',
            );

            my %h = %$headers;
            my $res = $http->delete($url, \%h);

            return {
                status  => $res->{status},
                success => $res->{success} ? 1 : 0,
                content => $res->{content} // '',
                headers => $res->{headers} // {},
                url     => $url,
            };
        },
    );
}

1;
