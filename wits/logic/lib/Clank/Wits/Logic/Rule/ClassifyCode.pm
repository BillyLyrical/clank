# CLANK-WIT: name=ClassifyCode
# CLANK-WIT: version=1.0.0
# CLANK-WIT: about=Classify code creation inputs into code domain
# CLANK-WIT: usage=Input: { text: "write a new function" } Output: { domain: "code", mode: "build", confidence: 1.0 }
# CLANK-WIT: hint=classify_code, classify, code, write, create, implement
# CLANK-WIT: author=Clank
# CLANK-WIT: license=Artistic-2.0
package Clank::Wits::Logic::Rule::ClassifyCode;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'classify_code',
        description => 'Classify code creation inputs into code domain',
        parameters  => {
            type       => 'object',
            properties => {
                text => { type => 'string', description => 'Input text to classify' },
            },
        },
        execute => sub {
            my ($args) = @_;
            my $input = $args;
            my $text = ref $input eq 'HASH' ? ($input->{text} // '') : $input;
            if ($text =~ /^(?:write|create|implement|add|build|function|class|module)/i) {
                return { domain => 'code', mode => 'build', confidence => 1.0 };
            }
            return undef;
        },
    );
}

1;
