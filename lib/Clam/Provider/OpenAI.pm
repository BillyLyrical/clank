package Clam::Provider::OpenAI;
use strict; use warnings;
use parent 'Clam::Provider';
# OpenAI API — api.openai.com/v1. Requires API key.

sub new {
    my ($c, %o) = @_;
    $o{base_url} //= 'https://api.openai.com/v1';
    return $c->SUPER::new(%o);
}
1;
