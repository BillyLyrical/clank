# CLANK-WIT: name=Run
# CLANK-WIT: version=1.0.0
# CLANK-WIT: about=Run the shared ruleset against text: pattern/fuzzy classification with confidence scores
# CLANK-WIT: usage=Input: { text: str, strategy?: first|all, dsl?: str } Output: { ok: 1, matched: 0|1, rule?, confidence?, result? }
# CLANK-WIT: hint=rule_run, run, ruleset, classify, match, execute
# CLANK-WIT: author=Clank
# CLANK-WIT: license=Artistic-2.0
package Clank::Wits::Logic::Rule::Run;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;
    my $store = $api->store;

    $api->register_tool(
        name        => 'rule.run',
        description => 'Run the shared ruleset against text: pattern/fuzzy classification with confidence scores',
        parameters  => {
            type       => 'object',
            properties => {
                text     => { type => 'string', description => 'Text to classify' },
                strategy => { type => 'string', description => 'Matching strategy: first or all' },
                dsl      => { type => 'string', description => 'Inline DSL rules (one-off)' },
            },
            required => ['text'],
        },
        execute => sub {
            my ($args) = @_;
            my $input = $args;
            use Clank::Rules;

            return { ok => 0, error => 'no store available' } unless $store;

            my $reg = $store->kv_get('rules.dsl');
            $reg = {} unless ref $reg eq 'HASH';
            my $dsl = ($reg->{dsl} // '');
            $dsl .= "\n$input->{dsl}" if defined $input->{dsl} && length "$input->{dsl}";

            my $text     = $input->{text} // '';
            my $strategy = $input->{strategy} // 'first';
            $strategy    = 'first' unless $strategy =~ /^(?:first|all)$/;

            unless (length $dsl) {
                return { ok => 1, matched => 0, matches => [], note => 'no rules in registry' };
            }

            my $rules = eval { Clank::Rules->parse($dsl) };
            return { ok => 0, error => "DSL parse failed: $@" } if $@;

            my $engine = Clank::Rules::Engine->new(store => $store, strategy => $strategy);
            $engine->load($rules);

            if ($strategy eq 'all') {
                my @matches;
                for my $m (@{ $engine->execute({ text => $text }) // [] }) {
                    next unless ref $m eq 'HASH';
                    my %r = %$m;
                    my ($conf, $rule) = (delete $r{_confidence}, delete $r{_rule});
                    push @matches, { rule => $rule, confidence => $conf, result => \%r };
                }
                return { ok => 1, matched => scalar(@matches) ? 1 : 0, matches => \@matches };
            }

            my $rule = $engine->find({ text => $text });
            unless ($rule) {
                return { ok => 1, matched => 0 };
            }
            my $res = $rule->execute({ text => $text }) // {};
            return {
                ok         => 1,
                matched    => 1,
                rule       => $rule->name,
                confidence => $rule->test({ text => $text }),
                result     => ref $res eq 'HASH' ? $res : { value => $res },
            };
        },
    );
}

1;
