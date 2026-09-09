package Clank::Provider::Ollama;
use strict; use warnings;
use parent 'Clank::Provider';
# Ollama local server — OpenAI-compatible at localhost:11434. No API key needed.

sub new {
    my ($c, %o) = @_;
    $o{base_url} //= 'http://localhost:11434/v1';
    $o{api_key}  //= '';
    return $c->SUPER::new(%o);
}
1;
