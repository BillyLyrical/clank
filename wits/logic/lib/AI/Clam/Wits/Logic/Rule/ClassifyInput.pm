# CLAM-WIT: name=ClassifyInput
# CLAM-WIT: version=1.0.0
# CLAM-WIT: about=Rules-first classification of user input (policy layer)
# CLAM-WIT: usage=Bus agent only. Input: the 'input' event payload { text, source }. Output: { action: transform, text, rule, ...classification }
# CLAM-WIT: hint=classify_input, classify, input, policy, rules_first, annotation
# CLAM-WIT: author=CLAM
# CLAM-WIT: license=Artistic-2.0
package AI::Clam::Wits::Logic::Rule::ClassifyInput;
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
            use AI::Clam::Rules;

            return unless $store;

            my $text = $input->{text} // '';
            return unless length $text;

            my $reg = $store->kv_get('rules.dsl');
            $reg = {} unless ref $reg eq 'HASH';
            my $dsl = $reg->{dsl} // '';
            return unless length $dsl;

            my $rules = eval { AI::Clam::Rules->parse($dsl) };
            return if $@ || !@$rules;

            my $engine = AI::Clam::Rules::Engine->new(store => $store, strategy => 'first');
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
