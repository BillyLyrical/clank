# CLAM-WIT: name=Greet
# CLAM-WIT: version=1.0.0
# CLAM-WIT: about=Rule: greet
# CLAM-WIT: usage=Input: { text: "hello world" } Output: { greeting: "Hello, hello world", confidence: 1.0 }
# CLAM-WIT: hint=greet, hello, greeting
# CLAM-WIT: author=CLAM
# CLAM-WIT: license=Artistic-2.0
package AI::Clam::Wits::Logic::Rule::Greet;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'greet',
        description => 'Rule: greet',
        parameters  => {
            type       => 'object',
            properties => {
                text => { type => 'string', description => 'Input text' },
            },
        },
        execute => sub {
            my ($args) = @_;
            my $input = $args;
            my $text = ref $input eq 'HASH' ? ($input->{text} // '') : $input;
            if ($text =~ /^hello/i) {
                return { greeting => "Hello, $text", confidence => 1.0 };
            }
            return undef;
        },
    );
}

1;
