package AI::Clam::Provider::OpenAI;
use strict; use warnings;
use parent 'AI::Clam::Provider';
# OpenAI API — api.openai.com/v1. Requires API key.

sub new {
    my ($c, %o) = @_;
    $o{base_url} //= 'https://api.openai.com/v1';
    return $c->SUPER::new(%o);
}
1;
