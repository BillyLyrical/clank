# CLANK-WIT: name=DetectNoWarnings
# CLANK-WIT: version=1.0.0
# CLANK-WIT: about=Detect missing 'use warnings'
# CLANK-WIT: usage=Input: { text: "use strict; sub foo {}" } Output: { found: 0, suggestion: "Add \"use warnings;\" at top" }
# CLANK-WIT: hint=detect_no_warnings, detect, warnings, perl, strict
# CLANK-WIT: author=Clank
# CLANK-WIT: license=Artistic-2.0
package Clank::Wits::Logic::Rule::DetectNoWarnings;
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
