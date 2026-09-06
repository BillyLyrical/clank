# CLAM-WIT: name=Dump
# CLAM-WIT: version=1.0.0
# CLAM-WIT: about=Add Data::Dumper output to variables
# CLAM-WIT: usage=Input: { code: "my $x = { foo => 1 };", vars: ["$x"] } Output: { code: "use Data::Dumper;\nmy $x = { foo => 1 };\nwarn Dumper($x);" }
# CLAM-WIT: hint=perl_dump, Data::Dumper, debug, dump variables
# CLAM-WIT: author=CLAM
# CLAM-WIT: license=Artistic-2.0
package Clam::Wits::Perl::Dump;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'perl_dump',
        description => 'Add Data::Dumper output to variables',
        parameters  => {
            type       => 'object',
            properties => {
                code => { type => 'string', description => 'Perl code' },
                vars => { type => 'array', items => { type => 'string' }, description => 'Variables to dump' },
            },
            required => ['code'],
        },
        execute => sub {
            my ($args) = @_;
            my $code = $args->{code} // '';
            my $vars = $args->{vars} // [];

            return { code => $code, error => "No code provided" } unless $code;

            my $dumper_code = $code;

            if ($dumper_code !~ /use\s+Data::Dumper/) {
                $dumper_code = "use Data::Dumper;\n" . $dumper_code;
            }

            for my $var (@$vars) {
                if ($dumper_code !~ /warn.*Dumper.*\Q$var\E/) {
                    $dumper_code .= "\nwarn Dumper($var);  # DEBUG\n";
                }
            }

            return { code => $dumper_code };
        },
    );
}

1;
