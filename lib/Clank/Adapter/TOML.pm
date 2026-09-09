# Clank::Adapter::TOML — compat shim for ported declarative wits that parse or
# emit TOML at runtime (e.g. fs.snapshot).  Delegates to Clank::Wit::File's
# parser; the encoder covers the same subset (scalars, arrays of scalars,
# nested hashes as [table] sections).
package Clank::Adapter::TOML;
use strict;
use warnings;
use Clank::Wit::File;

sub parse_toml {
    my ($str) = @_;
    return Clank::Wit::File::parse_toml($str, path => 'runtime');
}

sub encode_toml {
    my ($data) = @_;
    return '' unless ref $data eq 'HASH';
    my @out;
    for my $k (sort keys %$data) {      # root scalars first (TOML ordering)
        next if ref $data->{$k} eq 'HASH';
        push @out, "$k = " . _encode_scalar($data->{$k});
    }
    for my $k (sort keys %$data) {      # then [table] sections
        next unless ref $data->{$k} eq 'HASH';
        push @out, "[$k]";
        push @out, map { "$_ = " . _encode_scalar($data->{$k}{$_}) } sort keys %{ $data->{$k} };
    }
    return join("\n", @out) . "\n";
}

sub _encode_scalar {
    my ($v) = @_;
    return '[' . join(', ', map { _encode_scalar($_) } @$v) . ']' if ref $v eq 'ARRAY';
    return defined $v && $v =~ /^[+-]?\d+(?:\.\d+)?$/ ? "$v" : _quote($v);
}

sub _quote {
    my ($s) = @_;
    $s = '' unless defined $s;
    $s =~ s/\\/\\\\/g;
    $s =~ s/"/\\"/g;
    $s =~ s/\n/\\n/g;
    return qq{"$s"};
}

1;
