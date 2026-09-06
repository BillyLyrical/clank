# CLAM-WIT: name=DocCheck
# CLAM-WIT: version=1.0.0
# CLAM-WIT: about=Verify POD validity, find missing documentation
# CLAM-WIT: usage=Input: { code: "=head1 NAME\n\nMy module\n\n=cut\n\nsub foo { }" } Output: { valid: 1, missing: [...], sections: [...] }
# CLAM-WIT: hint=perl_doc_check, POD validation, documentation check, undocumented
# CLAM-WIT: author=CLAM
# CLAM-WIT: license=Artistic-2.0
package Clam::Wits::Perl::DocCheck;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'perl_doc_check',
        description => 'Verify POD validity, find missing documentation',
        parameters  => {
            type       => 'object',
            properties => {
                code => { type => 'string', description => 'Perl code with POD' },
            },
            required => ['code'],
        },
        execute => sub {
            my ($args) = @_;
            my $code = $args->{code} // '';

            return { valid => 0, error => "No code provided" } unless $code;

            my @sections;
            my $in_pod = 0;
            my @pod_lines;

            for my $line (split /\n/, $code) {
                if ($line =~ /^=(\w+)/) {
                    $in_pod = 1;
                    push @sections, $1;
                } elsif ($line =~ /^=cut/) {
                    $in_pod = 0;
                } elsif ($in_pod) {
                    push @pod_lines, $line;
                }
            }

            my @subs;
            while ($code =~ /^sub\s+(\w+)/gm) {
                push @subs, $1;
            }

            my @missing;
            for my $sub (@subs) {
                my $found = 0;
                for my $line (@pod_lines) {
                    if ($line =~ /\Q$sub\E/) {
                        $found = 1;
                        last;
                    }
                }
                push @missing, $sub unless $found;
            }

            my @required = qw(NAME DESCRIPTION SYNOPSIS);
            my @missing_sections;
            for my $req (@required) {
                push @missing_sections, $req unless grep { /^$req$/i } @sections;
            }

            return {
                valid           => scalar(@missing_sections) == 0,
                missing         => \@missing,
                missing_sections => \@missing_sections,
                sections        => \@sections,
            };
        },
    );
}

1;
