use strict; use warnings;
use Test::More;
use lib 'lib';
use File::Temp qw(tempdir);
use File::Path;

# Test skill discovery from multiple directories

use Clank::Skills;

my $dir = tempdir(CLEANUP => 1);

# Create skills/ structure (project root pattern)
my $skills_dir = "$dir/skills";
File::Path::make_path("$skills_dir/perl-style");
open my $fh, '>', "$skills_dir/perl-style/SKILL.md" or die;
print $fh <<'EOF';
---
name: perl-style
description: Perl coding conventions
---

# Perl Style

Use strict and warnings.
EOF
close $fh;

File::Path::make_path("$skills_dir/testing");
open $fh, '>', "$skills_dir/testing/SKILL.md" or die;
print $fh <<'EOF';
---
name: testing
description: Testing patterns
---

# Testing

Run prove -l t/.
EOF
close $fh;

# Create .clank/skills/ structure (user-level pattern)
my $clank_dir = "$dir/.clank/skills";
File::Path::make_path($clank_dir);
open $fh, '>', "$clank_dir/my-skill.md" or die;
print $fh <<'EOF';
---
name: my-custom-skill
description: A custom user skill
---

# Custom Skill

Do custom things.
EOF
close $fh;

# Discover from both directories
my @skills = Clank::Skills::discover(extra => [$skills_dir, $clank_dir]);

ok(@skills >= 3, 'discovered skills from multiple roots (got ' . scalar(@skills) . ')');

my %by_name = map { $_->{name} => $_ } @skills;
ok($by_name{'perl-style'}, 'perl-style skill found');
like($by_name{'perl-style'}{description}, qr/Perl coding conventions/, 'description parsed');
like($by_name{'perl-style'}{file_path}, qr{perl-style/SKILL\.md$}, 'file_path correct');

ok($by_name{'testing'}, 'testing skill found');
ok($by_name{'my-custom-skill'}, 'custom user skill found');

# Deduplication: same name from two roots
my $dup_dir = "$dir/dup";
File::Path::make_path($dup_dir);
open $fh, '>', "$dup_dir/SKILL.md" or die;
print $fh <<'EOF';
---
name: perl-style
description: Duplicate
---

# Dup
EOF
close $fh;

my @deduped = Clank::Skills::discover(extra => [$skills_dir, $dup_dir]);
my @perl_style = grep { $_->{name} eq 'perl-style' } @deduped;
is(scalar @perl_style, 1, 'deduplication: same name from two roots yields one');

# Frontmatter parsing
my $fm = Clank::Skills::parse_frontmatter("$skills_dir/perl-style/SKILL.md");
ok($fm, 'frontmatter parsed');
is($fm->{name}, 'perl-style', 'frontmatter name');
is($fm->{description}, 'Perl coding conventions', 'frontmatter description');

# Non-existent directory is silently skipped
my @empty = Clank::Skills::discover(extra => ['/nonexistent/path']);
ok(1, 'non-existent directory does not crash');

done_testing();
