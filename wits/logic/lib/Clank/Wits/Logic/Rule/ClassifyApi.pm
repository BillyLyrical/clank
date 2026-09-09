# CLANK-WIT: name=ClassifyApi
# CLANK-WIT: version=1.0.0
# CLANK-WIT: about=Classify API-related input
# CLANK-WIT: usage=Classifies input as API-related (route, endpoint, request, response, http, rest)
# CLANK-WIT: hint=classify, api, http, rest, endpoint, route
# CLANK-WIT: author=Clank
# CLANK-WIT: license=Artistic-2.0
package Clank::Wits::Logic::Rule::ClassifyApi;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;
    $api->register_tool(
        name        => 'classify_api',
        description => 'Rule: classify api',
        parameters  => { type => 'object', properties => { text => { type => 'string' } }, required => ['text'] },
        execute     => sub {
            my ($args) = @_;
            my $text = $args->{text} // '';
            if ($text =~ /\b(?:route|endpoint|request|response|http|rest|api|url)\b/i) {
                return { domain => 'api', tags => [qw(http web)] };
            }
            return undef;
        },
    );
}

1;
