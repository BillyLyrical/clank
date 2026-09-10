use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::RealBin/../lib";
use lib "$FindBin::RealBin/../../lib";

package MockAPI {
    sub new { bless { tools => [] }, shift }
    sub register_tool { my ($self, %def) = @_; push @{$self->{tools}}, \%def; return $def{name} }
    sub register_command { return }
    sub on { return 1 }
    sub store { return undef }
    sub ui { return undef }
}

package main;

my $mod = 'Clank::Wits::Perl::TddWorkflow';
eval "require $mod";
is($@, '', "$mod loads");
can_ok($mod, 'register');

my $api = MockAPI->new();
eval { $mod->register($api) };
is($@, '', "$mod registers ok");
ok(scalar @{$api->{tools}} > 0, "registered at least one tool");

my $tool = $api->{tools}[0];
is($tool->{name}, 'tdd_cycle', 'tool name is tdd_cycle');
ok($tool->{parameters}{required}, 'tool has required parameters');

done_testing;
