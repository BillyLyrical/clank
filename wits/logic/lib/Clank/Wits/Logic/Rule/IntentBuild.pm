# CLANK-WIT: name=IntentBuild
# CLANK-WIT: version=1.0.0
# CLANK-WIT: about=Detect build intent
# CLANK-WIT: usage=Input: { text: "make a new module" } Output: { intent: "build", mode: "build" }
# CLANK-WIT: hint=intent_build, intent, build, create, make, implement
# CLANK-WIT: author=Clank
# CLANK-WIT: license=Artistic-2.0
package Clank::Wits::Logic::Rule::IntentBuild;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'intent_build',
        description => 'Detect build intent',
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
            if ($text =~ /^(?:make|create|build|add|implement|write)\b/i) {
                return { intent => 'build', mode => 'build' };
            }
            return undef;
        },
    );
}

1;
