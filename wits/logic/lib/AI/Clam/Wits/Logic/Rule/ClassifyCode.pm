# CLAM-WIT: name=ClassifyCode
# CLAM-WIT: version=1.0.0
# CLAM-WIT: about=Classify code creation inputs into code domain
# CLAM-WIT: usage=Input: { text: "write a new function" } Output: { domain: "code", mode: "build", confidence: 1.0 }
# CLAM-WIT: hint=classify_code, classify, code, write, create, implement
# CLAM-WIT: author=CLAM
# CLAM-WIT: license=Artistic-2.0
package AI::Clam::Wits::Logic::Rule::ClassifyCode;
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
