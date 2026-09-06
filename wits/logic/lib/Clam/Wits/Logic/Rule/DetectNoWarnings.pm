# CLAM-WIT: name=DetectNoWarnings
# CLAM-WIT: version=1.0.0
# CLAM-WIT: about=Detect missing 'use warnings'
# CLAM-WIT: usage=Input: { text: "use strict; sub foo {}" } Output: { found: 0, suggestion: "Add \"use warnings;\" at top" }
# CLAM-WIT: hint=detect_no_warnings, detect, warnings, perl, strict
# CLAM-WIT: author=CLAM
# CLAM-WIT: license=Artistic-2.0
package Clam::Wits::Logic::Rule::DetectNoWarnings;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'detect_no_warnings',
        description => 'Detect missing \'use warnings\'',
        parameters  => {
            type       => 'object',
            properties => {
                text => { type => 'string', description => 'Perl source code to check' },
            },
        },
        execute => sub {
            my ($args) = @_;
            my $input = $args;
            my $text = ref $input eq 'HASH' ? ($input->{text} // '') : $input;
            if (($text =~ /\.pm$/ || $text =~ /\.pl$/) && $text !~ /^use warnings;/m) {
                return { found => 0, suggestion => 'Add "use warnings;" at top' };
            }
            return undef;
        },
    );
}

1;
