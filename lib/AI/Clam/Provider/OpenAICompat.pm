package AI::Clam::Provider::OpenAICompat;
use strict; use warnings;
use parent 'AI::Clam::Provider';
# Any OpenAI-compatible /v1/chat/completions endpoint (OpenRouter, Ollama, vLLM...).

sub new { my ($c,%o)=@_; my $s=$c->SUPER::new(%o); $s->{name} //= 'openai-compat'; return $s; }
1;
