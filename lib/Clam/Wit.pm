# Base class for Wits (clam plugins). A wit is a module with:
#   package Clam::Wit::<Name>;
#   sub new      { ... }                # optional; defaults to {}
#   sub register { my ($self,$api)=@_; }  # receives a Clam::Wit::API
package Clam::Wit;
use strict;
use warnings;

sub new {
    my ($class, %args) = @_;
    return bless { %args }, $class;
}

# Default: no registration. Wits override this.
sub register { }

1;
