use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::RealBin/../lib";
use lib "$FindBin::RealBin/../../lib";

package MockBus {
    sub new { bless { subs => {} }, shift }
    sub on {
        my ($self, $topic, $cb) = @_;
        push @{ $self->{subs}{$topic} }, $cb;
        return 1;
    }
    sub publish {
        my ($self, $topic, $payload) = @_;
        my @results;
        for my $cb (@{ $self->{subs}{$topic} // [] }) {
            my $r = $cb->({ topic => $topic, payload => $payload });
            push @results, $r if defined $r;
        }
        return { results => \@results };
    }
}

package MockAPI {
    sub new { bless { bus => MockBus->new, commands => [] }, shift }
    sub on { my ($self, @args) = @_; $self->{bus}->on(@args) }
    sub register_tool { return }
    sub register_command {
        my ($self, $name, %def) = @_;
        $def{name} = $name;
        push @{$self->{commands}}, \%def;
        return $name;
    }
    sub store { return undef }
    sub ui { return undef }
    sub bus { return $_[0]->{bus} }
}

package main;

require Clank::Wits::Build::GateGuard;

my $api = MockAPI->new();
Clank::Wits::Build::GateGuard->register($api);

ok(scalar @{ $api->{commands} } > 0, "registered commands");

my $bus = $api->{bus};

# --- Test 1: First edit attempt is blocked ---
my $r = $bus->publish('pre_tool_use', {
    name  => 'edit',
    input => { file_path => 'lib/Foo.pm', old => 'a', new => 'b' },
});
is(scalar @{ $r->{results} }, 1, "edit produced one result");
is($r->{results}[0]{block}, 1, "first edit is blocked");
like($r->{results}[0]{reason}, qr/Before editing lib\/Foo\.pm/, "block reason mentions file");
like($r->{results}[0]{reason}, qr/import\/require/, "demands importer search");
like($r->{results}[0]{reason}, qr/Quote the user/, "demands user instruction quote");

# --- Test 2: Second edit to same file is allowed ---
$r = $bus->publish('pre_tool_use', {
    name  => 'edit',
    input => { file_path => 'lib/Foo.pm', old => 'a', new => 'b' },
});
is(scalar @{ $r->{results} }, 0, "second edit to same file is allowed (no block)");

# --- Test 3: Different file is still blocked ---
$r = $bus->publish('pre_tool_use', {
    name  => 'edit',
    input => { file_path => 'lib/Bar.pm', old => 'a', new => 'b' },
});
is($r->{results}[0]{block}, 1, "different file is blocked");

# --- Test 4: write tool is also gated ---
$r = $bus->publish('pre_tool_use', {
    name  => 'write',
    input => { file_path => 'lib/New.pm', content => 'use strict;' },
});
is($r->{results}[0]{block}, 1, "write tool is gated");

# --- Test 5: read tool is NOT gated ---
$r = $bus->publish('pre_tool_use', {
    name  => 'read',
    input => { file_path => 'lib/Foo.pm' },
});
is(scalar @{ $r->{results} }, 0, "read tool is not gated");

# --- Test 6: grep tool is NOT gated ---
$r = $bus->publish('pre_tool_use', {
    name  => 'grep',
    input => { pattern => 'use Foo' },
});
is(scalar @{ $r->{results} }, 0, "grep tool is not gated");

# --- Test 7: Destructive bash is always blocked ---
$r = $bus->publish('pre_tool_use', {
    name  => 'bash',
    input => { command => 'rm -rf /tmp/build' },
});
is($r->{results}[0]{block}, 1, "destructive bash is blocked");
like($r->{results}[0]{reason}, qr/Destructive command/, "mentions destructive");
like($r->{results}[0]{reason}, qr/rollback/, "demands rollback procedure");

# --- Test 8: Destructive bash blocked again (not cached) ---
$r = $bus->publish('pre_tool_use', {
    name  => 'bash',
    input => { command => 'rm -rf /tmp/build' },
});
is($r->{results}[0]{block}, 1, "destructive bash blocked again");

# --- Test 9: Routine bash blocked once ---
$r = $bus->publish('pre_tool_use', {
    name  => 'bash',
    input => { command => 'prove -l t/' },
});
is($r->{results}[0]{block}, 1, "routine bash blocked first time");
like($r->{results}[0]{reason}, qr/one sentence/, "demands explanation");

# --- Test 10: Same routine bash allowed on retry ---
$r = $bus->publish('pre_tool_use', {
    name  => 'bash',
    input => { command => 'prove -l t/' },
});
is(scalar @{ $r->{results} }, 0, "same routine bash allowed on retry");

# --- Test 11: Different routine bash blocked ---
$r = $bus->publish('pre_tool_use', {
    name  => 'bash',
    input => { command => 'make test' },
});
is($r->{results}[0]{block}, 1, "different routine bash blocked");

# --- Test 12: /gateguard status command ---
my $status_cmd = (grep { $_->{name} eq 'gateguard' } @{ $api->{commands} })[0];
ok($status_cmd, "gateguard command registered");
my $status = $status_cmd->{handler}->(undef, 'status');
like($status, qr/files investigated/, "status shows investigated count");
like($status, qr/bash commands seen/, "status shows bash count");

# --- Test 13: /gateguard reset clears state ---
$status_cmd->{handler}->(undef, 'reset');
$r = $bus->publish('pre_tool_use', {
    name  => 'edit',
    input => { file_path => 'lib/Foo.pm', old => 'a', new => 'b' },
});
is($r->{results}[0]{block}, 1, "after reset, previously investigated file is blocked again");

# --- Test 14: Exempt glob skips gating ---
$status_cmd->{handler}->(undef, 'exempt t/**');
$r = $bus->publish('pre_tool_use', {
    name  => 'edit',
    input => { file_path => 't/01_test.t', old => 'a', new => 'b' },
});
is(scalar @{ $r->{results} }, 0, "exempted glob is not gated");

done_testing;
