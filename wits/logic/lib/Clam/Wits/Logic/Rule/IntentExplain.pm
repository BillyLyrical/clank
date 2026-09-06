# CLAM-WIT: name=IntentExplain
# CLAM-WIT: version=1.0.0
# CLAM-WIT: about=Detect explain intent
# CLAM-WIT: usage=Input: { text: "explain how this works" } Output: { intent: "explain", mode: "plan" }
# CLAM-WIT: hint=intent_explain, intent, explain, describe, how, why
# CLAM-WIT: author=CLAM
# CLAM-WIT: license=Artistic-2.0
package Clam::Wits::Logic::Rule::IntentExplain;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'intent_explain',
        description => 'Detect explain intent',
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
            if ($text =~ /^(?:what|how|why|explain|describe|show)\b/i) {
                return { intent => 'explain', mode => 'plan' };
            }
            return undef;
        },
    );
}

1;
