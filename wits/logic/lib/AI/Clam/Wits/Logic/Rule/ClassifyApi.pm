# CLAM-WIT: name=ClassifyApi
# CLAM-WIT: version=1.0.0
# CLAM-WIT: about=Classify API-related input
# CLAM-WIT: usage=Classifies input as API-related (route, endpoint, request, response, http, rest)
# CLAM-WIT: hint=classify, api, http, rest, endpoint, route
# CLAM-WIT: author=CLAM
# CLAM-WIT: license=Artistic-2.0
package AI::Clam::Wits::Logic::Rule::ClassifyApi;
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
