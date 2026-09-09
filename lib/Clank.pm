# Clank v2 - AI coding harness in Perl, modeled on Pi.
package Clank;
use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(builtin_tools version);

our $VERSION = '0.1.0';

sub version { return $VERSION }

# Built-in tools (Pi parity: read, bash, edit, write).
sub builtin_tools {
    require Clank::Tools::Read;
    require Clank::Tools::Bash;
    require Clank::Tools::Edit;
    require Clank::Tools::Write;
    return (
        Clank::Tools::Read->new,
        Clank::Tools::Bash->new,
        Clank::Tools::Edit->new,
        Clank::Tools::Write->new,
    );
}

1;
