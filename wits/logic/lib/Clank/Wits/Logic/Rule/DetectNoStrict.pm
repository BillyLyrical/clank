# CLANK-WIT: name=DetectNoStrict
# CLANK-WIT: version=1.0.0
# CLANK-WIT: about=Detect missing 'use strict'
# CLANK-WIT: usage=Input: { text: "use warnings; sub foo {}" } Output: { found: 0, suggestion: "Add \"use strict;\" at top" }
# CLANK-WIT: hint=detect_no_strict, detect, strict, perl, warnings
# CLANK-WIT: author=Clank
# CLANK-WIT: license=Artistic-2.0
package Clank::Wits::Logic::Rule::DetectNoStrict;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'detect_no_strict',
        description => 'Detect missing \'use strict\'',
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
            if (($text =~ /\.pm$/ || $text =~ /\.pl$/) && $text !~ /^use strict;/m) {
                return { found => 0, suggestion => 'Add "use strict;" at top' };
            }
            return undef;
        },
    );
}

1;
