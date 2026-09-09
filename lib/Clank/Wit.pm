# Base class for Wits (clank plugins). A wit is a module with:
#   package Clank::Wit::<Name>;
#   sub new      { ... }                # optional; defaults to {}
#   sub register { my ($self,$api)=@_; }  # receives a Clank::Wit::API
package Clank::Wit;
use strict;
use warnings;

sub new {
    my ($class, %args) = @_;
    return bless { %args }, $class;
}

# Default: no registration. Wits override this.
sub register { }

1;
