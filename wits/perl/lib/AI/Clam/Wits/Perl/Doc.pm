# CLAM-WIT: name=Doc
# CLAM-WIT: version=1.0.0
# CLAM-WIT: about=Extract or generate POD documentation for Perl code
# CLAM-WIT: usage=Input: { code: "sub foo { ... }", action: "extract" } Output: { pod: "=head1 foo\n\n..." }
# CLAM-WIT: hint=perl_doc, POD, documentation, extract, generate
# CLAM-WIT: author=CLAM
# CLAM-WIT: license=Artistic-2.0
package AI::Clam::Wits::Perl::Doc;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'perl_doc',
        description => 'Extract or generate POD documentation for Perl code',
        parameters  => {
            type       => 'object',
            properties => {
                code   => { type => 'string', description => 'Perl code' },
                action => { type => 'string', description => 'extract or generate', default => 'extract' },
            },
            required => ['code'],
        },
        execute => sub {
            my ($args) = @_;
            my $code = $args->{code} // '';
            my $action = $args->{action} // 'extract';

            return { pod => '', error => "No code provided" } unless $code;

            if ($action eq 'extract') {
                my $pod = '';
                my $in_pod = 0;
                for my $line (split /\n/, $code) {
                    if ($line =~ /^=(\w+)/) {
                        $in_pod = 1;
                        $pod .= "$line\n";
                    } elsif ($line =~ /^=cut/) {
                        $in_pod = 0;
                        $pod .= "$line\n";
                    } elsif ($in_pod) {
                        $pod .= "$line\n";
                    }
                }
                return { pod => $pod || "No POD found" };
            }

            if ($action eq 'generate') {
                my @subs;
                while ($code =~ /^sub\s+(\w+)\s*(?:\{|\(([^)]*)\)\s*\{)/gm) {
                    my $name = $1;
                    my $args = $2 // '';
                    push @subs, { name => $name, args => $args };
                }

                my $pod = "=head1 NAME\n\nModule - Description\n\n";
                $pod .= "=head1 SYNOPSIS\n\n    use Module;\n\n";
                $pod .= "=head1 DESCRIPTION\n\n";
                $pod .= "This module provides functionality.\n\n";

                for my $sub (@subs) {
                    $pod .= "=head2 $sub->{name}\n\n";
                    $pod .= "    $sub->{name}($sub->{args})\n\n";
                    $pod .= "Description of $sub->{name}.\n\n";
                }

                $pod .= "=head1 AUTHOR\n\nCLAM\n\n=cut\n";

                return { pod => $pod };
            }

            return { error => "Unknown action: $action" };
        },
    );
}

1;
