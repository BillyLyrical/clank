# Skill discovery: SKILL.md files with frontmatter (name/description), Pi-style.
package AI::Clam::Skills;
use strict;
use warnings;

# Scan ./.clam/skills and ~/.clam/skills (plus extras) for *.md skill files.
# Returns list of { name, description, file_path }.
sub discover {
    my (%o) = @_;
    my @roots = ('.clam/skills');
    push @roots, "$ENV{HOME}/.clam/skills" if defined $ENV{HOME};
    push @roots, @{ $o{extra} // [] };
    my (@skills, %seen);
    _scan($_, \@skills, \%seen) for grep { -d } @roots;
    return @skills;
}

sub _scan {
    my ($dir, $out, $seen) = @_;
    opendir(my $dh, $dir) or return;
    for my $e (sort readdir $dh) {
        next if $e =~ /^\./;
        my $p = "$dir/$e";
        if (-d $p) {
            _scan($p, $out, $seen);
        } elsif ($e eq 'SKILL.md' || $e =~ /\.md$/) {
            my $fm = parse_frontmatter($p);
            next unless $fm && defined $fm->{name};
            next if $seen->{ $fm->{name} }++;
            push @$out, {
                name        => $fm->{name},
                description => $fm->{description} // '',
                file_path   => $p,
            };
        }
    }
    closedir $dh;
}

# Minimal YAML frontmatter: "key: value" lines between leading --- markers.
sub parse_frontmatter {
    my ($file) = @_;
    open my $fh, '<', $file or return undef;
    my $first = <$fh>;
    unless (defined $first && $first =~ /^---\s*\n/) { close $fh; return undef }
    my %fm;
    while (my $l = <$fh>) {
        last if $l =~ /^---\s*$/;
        next unless $l =~ /^([\w-]+)\s*:\s*(.*)$/;
        my ($k, $v) = ($1, $2);
        $v =~ s/^["'](.*)["']$/$1/;
        $fm{$k} = $v;
    }
    close $fh;
    return %fm ? \%fm : undef;
}

1;
