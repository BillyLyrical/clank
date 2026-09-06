#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

use Clam::Store;
use Clam::Bus;
use Clam::Constraints;

my $store = Clam::Store->new(db => ':memory:');
my $bus   = Clam::Bus->new(store => $store);

# === Test 1: Construction ===

subtest 'Construction' => sub {
    my $c = Clam::Constraints->new;
    isa_ok($c, 'Clam::Constraints');
    my $schemas = $c->list_schemas;
    ok(scalar @$schemas >= 3, 'has built-in schemas');
};

# === Test 2: List schemas ===

subtest 'List schemas' => sub {
    my $c = Clam::Constraints->new;
    my $schemas = $c->list_schemas;
    my @names = map { $_->{name} } @$schemas;
    ok(scalar @names >= 3, 'multiple schemas registered');
    ok((grep { $_ eq 'vagueness' } @names), 'vagueness present');
    ok((grep { $_ eq 'overclaiming' } @names), 'overclaiming present');
    ok((grep { $_ eq 'wm_contradiction' } @names), 'wm_contradiction present');
};

# === Test 3: Vagueness constraint ===

subtest 'Vagueness: flags excessive hedging' => sub {
    my $c = Clam::Constraints->new;
    my $output = "Maybe it could work. Perhaps it might be possible. It depends on many factors. "
               . "Generally this sort of approach might be possibly useful. Sort of like a kind of solution.";
    my $v = $c->validate($output, {});
    my @vague = grep { $_->{schema} eq 'vagueness' } @$v;
    ok(scalar @vague >= 1, 'vagueness violation detected');
};

subtest 'Vagueness: passes specific output' => sub {
    my $c = Clam::Constraints->new;
    my $v = $c->validate('The function returns 42. It takes two arguments: x and y.', {});
    my @vague = grep { $_->{schema} eq 'vagueness' } @$v;
    is(scalar @vague, 0, 'no vagueness violation for specific output');
};

# === Test 4: Overclaiming constraint ===

subtest 'Overclaiming: flags absolute claims' => sub {
    my $c = Clam::Constraints->new;
    my $v = $c->validate('This code always works without exception and is 100% correct.', {});
    my @over = grep { $_->{schema} eq 'overclaiming' } @$v;
    ok(scalar @over >= 1, 'overclaiming violation detected');
};

# === Test 5: Constraint with world model ===

subtest 'WM contradiction: detects contradiction' => sub {
    my $wm_store = Clam::Store->new(db => ':memory:');
    use Clam::WorldModel;
    my $wm = Clam::WorldModel->new(store => $wm_store);

    $wm->add_entity(id => 'perl', type => 'language', name => 'Perl');
    $wm->assert_fact(entity_id => 'perl', predicate => 'type', value => 'scripting language', source => 'user');

    my $c = Clam::Constraints->new(world_model => $wm);
    my $v = $c->validate('Perl is not a scripting language.', {});
    my @wm_v = grep { $_->{schema} eq 'wm_contradiction' } @$v;
    ok(scalar @wm_v >= 1, 'contradiction detected');
    like($wm_v[0]{message}, qr/known fact/i, 'mentions known fact');
};

subtest 'WM contradiction: no false positives' => sub {
    my $wm_store = Clam::Store->new(db => ':memory:');
    use Clam::WorldModel;
    my $wm = Clam::WorldModel->new(store => $wm_store);

    $wm->add_entity(id => 'perl', type => 'language', name => 'Perl');
    $wm->assert_fact(entity_id => 'perl', predicate => 'type', value => 'scripting language', source => 'user');

    my $c = Clam::Constraints->new(world_model => $wm);
    my $v = $c->validate('Perl is a scripting language.', {});
    my @wm_v = grep { $_->{schema} eq 'wm_contradiction' } @$v;
    is(scalar @wm_v, 0, 'no false positive');
};

# === Test 6: Severity levels ===

subtest 'Severity: strict violations detected' => sub {
    my $wm_store = Clam::Store->new(db => ':memory:');
    use Clam::WorldModel;
    my $wm = Clam::WorldModel->new(store => $wm_store);
    $wm->add_entity(id => 'x', type => 'thing', name => 'X');
    $wm->assert_fact(entity_id => 'x', predicate => 'is', value => 'blue', source => 'user');

    my $c = Clam::Constraints->new(world_model => $wm);
    my $v = $c->validate('X is not blue.', {});
    ok($c->has_blocking_violations($v), 'has blocking violations');
};

subtest 'Severity: warn violations not blocking' => sub {
    my $c = Clam::Constraints->new;
    my $v = $c->validate('This code always works.', {});
    ok(!$c->has_blocking_violations($v), 'no blocking violations for warn-only');
};

# === Test 7: Custom constraint ===

subtest 'Custom constraint: register and validate' => sub {
    my $c = Clam::Constraints->new;
    $c->add_constraint(
        name     => 'no_jargon',
        desc     => 'Avoid technical jargon',
        severity => 'warn',
        fn       => sub {
            my ($output) = @_;
            my @v;
            push @v, 'Contains jargon' if $output =~ /\b(?:monad|functor|kleisli)\b/i;
            return @v;
        },
    );

    my $v = $c->validate('This uses a monad for composition.', {});
    my @jargon = grep { $_->{schema} eq 'no_jargon' } @$v;
    ok(scalar @jargon >= 1, 'custom constraint fires');
};

# === Test 8: Unregister ===

subtest 'Unregister constraint' => sub {
    my $c = Clam::Constraints->new;
    my $before = scalar @{$c->list_schemas};
    $c->add_constraint(name => 'temp', fn => sub { () });
    is(scalar @{$c->list_schemas}, $before + 1, 'added');
    $c->remove_constraint('temp');
    is(scalar @{$c->list_schemas}, $before, 'removed');
};

# === Test 9: Set severity ===

subtest 'Set severity' => sub {
    my $c = Clam::Constraints->new;
    $c->set_severity('vagueness', 'strict');
    my $schemas = $c->list_schemas;
    my ($s) = grep { $_->{name} eq 'vagueness' } @$schemas;
    is($s->{severity}, 'strict', 'severity updated');
};

# === Test 10: Format for revision ===

subtest 'Format for revision' => sub {
    my $c = Clam::Constraints->new;
    my $v = $c->validate('This code always works.', {});
    my $msg = $c->format_for_revision($v);
    like($msg, qr/overclaiming/, 'contains schema name');
    ok(length($msg) > 0, 'has message content');
};

# === Test 11: Bus integration ===

subtest 'Bus: message_end triggers validation' => sub {
    my $bus_store = Clam::Store->new(db => ':memory:');
    my $bus = Clam::Bus->new(store => $bus_store);
    require Clam::Wit::API;
    my $api = Clam::Wit::API->new(bus => $bus, store => $bus_store);
    my $c = Clam::Constraints->new;
    $c->register($api);

    my $result = $bus->publish('message_end', {
        role    => 'assistant',
        content => { text => 'This code always works without exception.', tool_calls => [] },
    });

    my @violations = grep { ref $_ eq 'HASH' && ref $_->{content}{_violations} eq 'ARRAY' } @{$result->{results}};
    ok(scalar @violations >= 1, 'constraint violation returned from bus');
};

# === Test 12: Multiple violations ===

subtest 'Multiple violations in one output' => sub {
    my $wm_store = Clam::Store->new(db => ':memory:');
    use Clam::WorldModel;
    my $wm = Clam::WorldModel->new(store => $wm_store);
    $wm->add_entity(id => 'perl', type => 'language', name => 'Perl');
    $wm->assert_fact(entity_id => 'perl', predicate => 'is', value => 'compiled', source => 'user');

    my $c = Clam::Constraints->new(world_model => $wm);
    my $v = $c->validate(
        'Perl is not compiled. This code always works without exception.',
        { conversation => 'I feel upset about this.' }
    );
    ok(scalar @$v >= 2, 'multiple violations detected');
    my @schemas = map { $_->{schema} } @$v;
    ok((grep { $_ eq 'wm_contradiction' } @schemas), 'contradiction found');
    ok((grep { $_ eq 'overclaiming' } @schemas), 'overclaiming found');
};

done_testing;
