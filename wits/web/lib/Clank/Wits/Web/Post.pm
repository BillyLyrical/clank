# CLANK-WIT: name=Post
# CLANK-WIT: version=1.0.0
# CLANK-WIT: about=HTTP POST request with JSON or form data
# CLANK-WIT: usage=Input: { url: "https://api.example.com/data", content: "{\"key\":\"val\"}", content_type: "application/json" } Output: { status: 201, content: "..." }
# CLANK-WIT: hint=http post request, api call, send data, rest
# CLANK-WIT: author=Clank
# CLANK-WIT: license=Artistic-2.0
package Clank::Wits::Web::Post;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;
    $api->register_tool(
        name        => 'web_post',
        description => 'HTTP POST request with JSON or form data',
        parameters  => {
            type       => 'object',
            properties => {
                url          => { type => 'string', description => 'URL to post to' },
                content      => { type => 'string', description => 'Request body' },
                content_type => { type => 'string', description => 'Content-Type header', default => 'application/json' },
                timeout      => { type => 'integer', description => 'Timeout in seconds', default => 30 },
                headers      => { type => 'object', description => 'Additional headers' },
            },
            required => ['url'],
        },
        execute => sub {
            my ($args) = @_;
            my $url          = $args->{url}          // '';
            my $content      = $args->{content}      // '';
            my $content_type = $args->{content_type} // 'application/json';
            my $timeout      = $args->{timeout}      // 30;
            my $headers      = $args->{headers}      // {};

            return { error => "No URL provided" } unless $url;
            return { error => "URL must start with http" } unless $url =~ m{^https?://};

            eval { require HTTP::Tiny; 1 } or return { error => "HTTP::Tiny not installed" };

            my $http = HTTP::Tiny->new(
                timeout => $timeout,
                agent   => 'Clank/1.0',
            );

            my %h = %$headers;
            $h{'Content-Type'} = $content_type;
            my $res = $http->post($url, {
                content => $content,
                headers => \%h,
            });

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
