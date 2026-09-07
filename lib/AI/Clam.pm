# CLAM v2 - AI coding harness in Perl, modeled on Pi.
package AI::Clam;
use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(builtin_tools version);

our $VERSION = '0.1.0';

sub version { return $VERSION }

# Built-in tools (Pi parity: read, bash, edit, write).
sub builtin_tools {
    require AI::Clam::Tools::Read;
    require AI::Clam::Tools::Bash;
    require AI::Clam::Tools::Edit;
    require AI::Clam::Tools::Write;
    return (
        AI::Clam::Tools::Read->new,
        AI::Clam::Tools::Bash->new,
        AI::Clam::Tools::Edit->new,
        AI::Clam::Tools::Write->new,
    );
}

1;
