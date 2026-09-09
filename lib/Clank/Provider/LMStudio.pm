package Clank::Provider::LMStudio;
use strict; use warnings;
use parent 'Clank::Provider';
# Local LM Studio server (default http://localhost:1234/v1). No API key needed.

sub new { my ($c,%o)=@_; $o{api_key} //= ''; return $c->SUPER::new(%o); }
1;
