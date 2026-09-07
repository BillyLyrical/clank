use strict; use warnings;
use Test::More;
use lib 'lib';
use AI::Clam::Util qw(uuid4 now_ms jencode jdecode truncate_head truncate_tail estimate_tokens);

# uuid4 format + uniqueness
my %seen;
for my $i (1 .. 200) {
    my $u = uuid4();
    like($u, qr/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/, 'uuid4 format') if $i <= 3;
    ok(!$seen{$u}++, "uuid unique ($i)");
}

# json round-trip
my $orig = { a => [1,2], b => 'x' };
is_deeply(jdecode(jencode($orig)), $orig, 'json roundtrip');

# truncate_head: line cap
my ($out, %t) = truncate_head("a\nb\nc", max_lines => 2);
is($out, "a\nb", 'head keeps first lines');
ok($t{truncated}, 'head truncated flag');

# truncate_tail: byte cap keeps the END
my $big = join("\n", map { "line$_" x 50 } 1 .. 20);
my ($tout, %tt) = truncate_tail($big, max_bytes => 300);
ok($tt{truncated}, 'tail truncated');
like($tout, qr/line20/, 'tail keeps last lines');

# token estimate
is(estimate_tokens("a" x 400), 100, '~4 chars/token');

done_testing();
