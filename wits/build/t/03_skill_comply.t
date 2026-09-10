#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";

package MockAPI {
    sub new { bless { tools => [], commands => [] }, shift }
    sub register_tool { my ($self, %def) = @_; push @{$self->{tools}}, \%def; return $def{name} }
    sub register_command { my ($self, $name, %def) = @_; $def{name} = $name; push @{$self->{commands}}, \%def; return $name }
    sub on { return 1 }
    sub store { return undef }
    sub ui { return undef }
}

package main;

require Clank::Wits::Build::SkillComply;

# === Test 1: parse_wit_metadata ===

subtest 'Parse wit metadata' => sub {
    my $meta = Clank::Wits::Build::SkillComply::parse_wit_metadata(
        'wits/build/lib/Clank/Wits/Build/GateGuard.pm');
    ok(defined $meta, 'parsed metadata');
    is($meta->{name}, 'GateGuard', 'name');
    like($meta->{about}, qr/fact-forcing/i, 'about');
    like($meta->{hint}, qr/gateguard/i, 'hint');
};

# === Test 2: scan_wits finds all wits ===

subtest 'Scan wits' => sub {
    my $wits = Clank::Wits::Build::SkillComply::scan_wits(dir => 'wits');
    ok(scalar @$wits > 10, 'found multiple wits');

    my @names = map { $_->{name} } @$wits;
    ok(grep { $_ eq 'GateGuard' } @names, 'found GateGuard');
    ok(grep { $_ eq 'Test' } @names, 'found Perl::Test');
    ok(grep { $_ eq 'SearchFirst' } @names, 'found SearchFirst');

    for my $w (@$wits) {
        ok(defined $w->{deck}, "$w->{name} has deck");
        ok(defined $w->{hint}, "$w->{name} has hint");
    }
};

# === Test 3: score_prompt ranks correctly ===

subtest 'Score prompt' => sub {
    my $wits = Clank::Wits::Build::SkillComply::scan_wits(dir => 'wits');

    my $scored = Clank::Wits::Build::SkillComply::score_prompt(
        'run perl tests and parse TAP output', $wits);
    ok(scalar @$scored > 0, 'scored results');
    is($scored->[0]{wit}{name}, 'Test', 'Perl::Test ranks first');
};

# === Test 4: score_prompt for gatekeeper scenario ===

subtest 'Score gateguard prompt' => sub {
    my $wits = Clank::Wits::Build::SkillComply::scan_wits(dir => 'wits');

    my $scored = Clank::Wits::Build::SkillComply::score_prompt(
        'block edits until investigation', $wits);
    ok(scalar @$scored > 0, 'scored results');
    is($scored->[0]{wit}{name}, 'GateGuard', 'GateGuard ranks first');
};

# === Test 5: compliance_check tool registers ===

subtest 'Tool registration' => sub {
    my $api = MockAPI->new();
    Clank::Wits::Build::SkillComply->register($api);

    my @tools = grep { $_->{name} eq 'compliance_check' } @{$api->{tools}};
    is(scalar @tools, 1, 'compliance_check registered');
    ok(scalar @{$api->{commands}} > 0, 'commands registered');
};

# === Test 6: compliance_check runs without error ===

subtest 'Compliance check runs' => sub {
    my $api = MockAPI->new();
    Clank::Wits::Build::SkillComply->register($api);

    my $tool = (grep { $_->{name} eq 'compliance_check' } @{$api->{tools}})[0];
    my $result = $tool->{execute}->({});
    ok(defined $result, 'result defined');
    ok(ref $result eq 'HASH', 'result is hashref');
    ok(exists $result->{compliance}, 'has compliance');
    ok(exists $result->{gaps}, 'has gaps');
    ok(exists $result->{scanned}, 'has scanned count');
    ok($result->{scanned} > 0, 'scanned wits');
    ok(scalar @{$result->{compliance}} > 0, 'has compliance entries');
};

# === Test 7: compliance_check for specific wit ===

subtest 'Compliance for specific wit' => sub {
    my $api = MockAPI->new();
    Clank::Wits::Build::SkillComply->register($api);

    my $tool = (grep { $_->{name} eq 'compliance_check' } @{$api->{tools}})[0];
    my $result = $tool->{execute}->({ wit => 'GateGuard' });
    is(scalar @{$result->{compliance}}, 1, 'one compliance entry');
    is($result->{compliance}[0]{wit}, 'GateGuard', 'correct wit');
};

# === Test 8: compliance_check for deck ===

subtest 'Compliance for deck' => sub {
    my $api = MockAPI->new();
    Clank::Wits::Build::SkillComply->register($api);

    my $tool = (grep { $_->{name} eq 'compliance_check' } @{$api->{tools}})[0];
    my $result = $tool->{execute}->({ deck => 'build' });
    ok(scalar @{$result->{compliance}} >= 3, 'multiple build wits checked');
    for my $c (@{$result->{compliance}}) {
        is($c->{deck}, 'build', "$c->{wit} is in build deck");
    }
};

# === Test 9: compliance_check with custom prompts ===

subtest 'Custom prompts' => sub {
    my $api = MockAPI->new();
    Clank::Wits::Build::SkillComply->register($api);

    my $tool = (grep { $_->{name} eq 'compliance_check' } @{$api->{tools}})[0];
    my $result = $tool->{execute}->({
        wit => 'SearchFirst',
        prompts => ['search for existing CPAN modules', 'what is the meaning of life'],
    });
    is(scalar @{$result->{compliance}}, 1, 'one entry');
    is($result->{compliance}[0]{expected}, 2, 'two custom prompts');
};

# === Test 10: unknown wit returns error ===

subtest 'Unknown wit' => sub {
    my $api = MockAPI->new();
    Clank::Wits::Build::SkillComply->register($api);

    my $tool = (grep { $_->{name} eq 'compliance_check' } @{$api->{tools}})[0];
    my $result = $tool->{execute}->({ wit => 'NonexistentWit' });
    ok(scalar @{$result->{gaps}} > 0, 'has gap message');
    like($result->{gaps}[0], qr/not found/, 'not found message');
};

# === Test 11: /comply command ===

subtest 'Comply command' => sub {
    my $api = MockAPI->new();
    Clank::Wits::Build::SkillComply->register($api);

    my $cmd = (grep { $_->{name} eq 'comply' } @{$api->{commands}})[0];
    ok(defined $cmd, 'comply command registered');
    my $output = $cmd->{handler}->(undef, 'GateGuard');
    like($output, qr/Compliance Report/, 'report header');
    like($output, qr/GateGuard/, 'mentions wit');
};

done_testing();
