# CLAM v2 - AI coding harness in Perl, modeled on Pi.
package Clam;
use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(builtin_tools version);

our $VERSION = '0.1.0';

sub version { return $VERSION }

# Built-in tools (Pi parity: read, bash, edit, write).
sub builtin_tools {
    require Clam::Tools::Read;
    require Clam::Tools::Bash;
    require Clam::Tools::Edit;
    require Clam::Tools::Write;
    return (
        Clam::Tools::Read->new,
        Clam::Tools::Bash->new,
        Clam::Tools::Edit->new,
        Clam::Tools::Write->new,
    );
}

1;
