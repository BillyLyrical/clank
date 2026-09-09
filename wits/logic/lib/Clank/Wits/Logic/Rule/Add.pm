# CLANK-WIT: name=Add
# CLANK-WIT: version=1.0.0
# CLANK-WIT: about=Add a classification rule to the shared ruleset
# CLANK-WIT: usage=Input: { dsl?: str } or { name: str, when: str, then?: [str], priority?: int, domain?: str } Output: { ok: 1, rule: name, total_rules: N } or { ok: 0, error: str }
# CLANK-WIT: hint=rule_add, add, rule, dsl, classify, persist
# CLANK-WIT: author=Clank
# CLANK-WIT: license=Artistic-2.0
package Clank::Wits::Logic::Rule::Add;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;
    my $store = $api->store;

    $api->register_tool(
        name        => 'rule.add',
        description => 'Add a classification rule to the shared ruleset',
        parameters  => {
            type       => 'object',
            properties => {
                dsl      => { type => 'string', description => 'Raw DSL text for the rule' },
                name     => { type => 'string', description => 'Rule name' },
                when     => { type => 'string', description => 'Match condition' },
                then     => { type => 'array',  description => 'Actions to take' },
                priority => { type => 'integer', description => 'Rule priority' },
                domain   => { type => 'string', description => 'Domain classification' },
            },
        },
        execute => sub {
            my ($args) = @_;
            my $input = $args;
            use Clank::Rules;

            return { ok => 0, error => 'no store available' } unless $store;

            my $dsl = $input->{dsl};
            if (!defined $dsl || !length "$dsl") {
                my ($name, $when) = ($input->{name}, $input->{when});
                return { ok => 0, error => 'need dsl text or (name + when)' }
                    unless defined $name && length "$name" && defined $when && length "$when";
                my @then = @{ $input->{then} // [] };
                push @then, "tag matched" unless @then;
                $dsl = "rule $name\n  when $when\n" . join("\n", map { "  then $_" } @then) . "\nend\n";
            }

            my $rules = eval { Clank::Rules->parse($dsl) };
            return { ok => 0, error => "DSL parse failed: $@" } if $@;
            return { ok => 0, error => 'DSL parsed zero rules' } unless @$rules;

            my $key = 'rules.dsl';
            my $reg = $store->kv_get($key);
            $reg = {} unless ref $reg eq 'HASH';
            my $cur = ($reg->{dsl} // '') . "\n" . $dsl;
            $store->kv_set($key, { dsl => $cur });

            my $all = eval { Clank::Rules->parse($cur) };
            return { ok => 0, error => "registry corrupted after append: $@" } if $@;

            return { ok => 1, rule => $rules->[0]->name, total_rules => scalar @$all };
        },
    );
}

1;
