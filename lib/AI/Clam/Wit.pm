# Base class for Wits (clam plugins). A wit is a module with:
#   package AI::Clam::Wit::<Name>;
#   sub new      { ... }                # optional; defaults to {}
#   sub register { my ($self,$api)=@_; }  # receives a AI::Clam::Wit::API
package AI::Clam::Wit;
use strict;
use warnings;

sub new {
    my ($class, %args) = @_;
    return bless { %args }, $class;
}

# Default: no registration. Wits override this.
sub register { }

1;
