# CLAM-WIT: name=DetectNoStrict
# CLAM-WIT: version=1.0.0
# CLAM-WIT: about=Detect missing 'use strict'
# CLAM-WIT: usage=Input: { text: "use warnings; sub foo {}" } Output: { found: 0, suggestion: "Add \"use strict;\" at top" }
# CLAM-WIT: hint=detect_no_strict, detect, strict, perl, warnings
# CLAM-WIT: author=CLAM
# CLAM-WIT: license=Artistic-2.0
package Clam::Wits::Logic::Rule::DetectNoStrict;
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
