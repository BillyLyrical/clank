# CLAM-WIT: name=Syntax
# CLAM-WIT: version=1.0.0
# CLAM-WIT: about=Check Perl syntax with perl -c, return errors/warnings
# CLAM-WIT: usage=Input: { code: "sub foo { my $x = }", file: "test.pl" } Output: { ok: 0, errors: [...] }
# CLAM-WIT: hint=perl_syntax, syntax check, perl -c, compile errors
# CLAM-WIT: author=CLAM
# CLAM-WIT: license=Artistic-2.0
package AI::Clam::Wits::Perl::Syntax;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'perl_syntax',
        description => 'Check Perl syntax with perl -c, return errors/warnings',
        parameters  => {
            type       => 'object',
            properties => {
                code => { type => 'string', description => 'Perl code to check' },
                file => { type => 'string', description => 'Filename for error messages', default => 'check.pl' },
            },
            required => ['code'],
        },
        execute => sub {
            my ($args) = @_;
            my $code = $args->{code} // '';
            my $file = $args->{file} // 'check.pl';

            return { ok => 0, errors => ["No code provided"] } unless $code;

            my $tmp = "/tmp/clam_syntax_check_$$.pl";
            open my $fh, '>', $tmp or return { ok => 0, errors => ["Cannot write temp file: $!"] };
            print $fh $code;
            close $fh;

            my $output = `$^X -c $tmp 2>&1`;
            my $exit = $? >> 8;
            unlink $tmp;

            my @errors;
            for my $line (split /\n/, $output) {
                next if $line =~ /^$file syntax OK/;
                push @errors, $line if $line =~ /error|warn|syntax/i;
            }

            return {
                ok     => $exit == 0,
                errors => \@errors,
                output => $output,
            };
        },
    );
}

1;
