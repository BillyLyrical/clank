use strict; use warnings;
use Test::More;
use lib 'lib';
use lib 'wits/psh/lib';
use Clank::Wits::Psh::Eval;

# Mock API to capture registered tools
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

my $api = MockAPI->new();
Clank::Wits::Psh::Eval->register($api);

# Find psh_sandbox tool
my ($sandbox_def) = grep { $_->{name} eq 'psh_sandbox' } @{$api->{tools}};
ok($sandbox_def, 'psh_sandbox registered');
my $sandbox = $sandbox_def->{execute};

# basic execution
my $r = $sandbox->({ code => 'print "hello-sandbox"' });
is($r->{ok}, 1, 'sandbox basic ok');
is($r->{result}, 'hello-sandbox', 'sandbox stdout captured');
is($r->{type}, 'perl_sandbox', 'sandbox type');

# syntax error
$r = $sandbox->({ code => 'syntax error here !!!' });
ok(!$r->{ok}, 'sandbox syntax error');
like($r->{stderr}, qr/syntax|error/i, 'sandbox error in stderr');

# timeout
$r = $sandbox->({ code => 'sleep 10', timeout => 1 });
ok(!$r->{ok}, 'sandbox timeout');
like($r->{error}, qr/timed out/, 'sandbox timeout message');

# no code
$r = $sandbox->({});
ok(!$r->{ok}, 'sandbox no code');
like($r->{error}, qr/No code/, 'sandbox no code error');

# nonzero exit
$r = $sandbox->({ code => 'exit 42' });
ok(!$r->{ok}, 'sandbox nonzero exit');
is($r->{exit}, 42, 'sandbox exit code preserved');

# isolation: code can't see parent state
$r = $sandbox->({ code => 'print $main::some_parent_var // "undef"' });
is($r->{result}, 'undef', 'sandbox isolated from parent vars');

done_testing();
