# CLANK-WIT: name=ClassifyInput
# CLANK-WIT: version=1.0.0
# CLANK-WIT: about=Rules-first classification of user input (policy layer)
# CLANK-WIT: usage=Bus agent only. Input: the 'input' event payload { text, source }. Output: { action: transform, text, rule, ...classification }
# CLANK-WIT: hint=classify_input, classify, input, policy, rules_first, annotation
# CLANK-WIT: author=Clank
# CLANK-WIT: license=Artistic-2.0
package Clank::Wits::Logic::Rule::ClassifyInput;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;
    my $store = $api->store;

    $api->register_tool(
        name        => 'rule.classify_input',
        description => 'Rules-first classification of user input (policy layer)',
        parameters  => {
            type       => 'object',
            properties => {
                text   => { type => 'string', description => 'Input text to classify' },
                source => { type => 'string', description => 'Source of the input' },
            },
        },
        execute => sub {
            my ($args) = @_;
            my $input = $args;
            use Clank::Rules;

            return unless $store;

            my $text = $input->{text} // '';
            return unless length $text;

            my $reg = $store->kv_get('rules.dsl');
            $reg = {} unless ref $reg eq 'HASH';
            my $dsl = $reg->{dsl} // '';
            return unless length $dsl;

            my $rules = eval { Clank::Rules->parse($dsl) };
            return if $@ || !@$rules;

            my $engine = Clank::Rules::Engine->new(store => $store, strategy => 'first');
            $engine->load($rules);

            my $rule = $engine->find({ text => $text });
            return unless $rule;

            my $res = $rule->execute({ text => $text }) // {};
            my %res = ref $res eq 'HASH' ? %$res : ();

            my @tag = "rule=$rule->{name}";
            push @tag, "domain=$res{domain}" if defined $res{domain};
            push @tag, "mode=$res{mode}"     if defined $res{mode};

            return {
                action => 'transform',
                text   => "[rules: " . join(' ', @tag) . "] $text",
                rule   => $rule->{name},
                %res,
            };
        },
    );
}

1;
