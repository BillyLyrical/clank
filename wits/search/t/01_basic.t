use strict;
use warnings;
use Test::More;
use FindBin;
use File::Find;
use lib "$FindBin::RealBin/../lib";
use lib "$FindBin::RealBin/../../lib";

package MockAPI {
    sub new { bless { tools => [] }, shift }
    sub register_tool { my ($self, %def) = @_; push @{$self->{tools}}, \%def; return $def{name} }
    sub register_command { return }
    sub on { return 1 }
    sub track_sub { return 1 }
    sub ui { return undef }
    sub bus { return undef }
    sub store { return undef }
    sub session { return undef }
    sub wit_name { return 'test' }
}

package main;

my $lib = "$FindBin::RealBin/../lib";
my $Deck = 'Search';
my @pm;
find(sub { push @pm, $File::Find::name if /\.pm$/ && -f $_ }, "$lib/AI/Clam/Wits/$Deck");

plan tests => scalar(@pm) * 3;

for my $path (sort @pm) {
    (my $rel = $path) =~ s{.*Clam/Wits/$Deck/}{};
    $rel =~ s{\.pm$}{};
    my $mod = "AI::Clam::Wits::${Deck}::" . join("::", split m{/}, $rel);
    eval "require $mod";
    is($@, '', "$mod loads");
    can_ok($mod, 'register');
    my $api = MockAPI->new();
    eval { $mod->register($api) };
    is($@, '', "$mod registers ok");
}

done_testing;
