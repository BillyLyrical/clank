# CLAM-WIT: name=Explain
# CLAM-WIT: version=1.0.0
# CLAM-WIT: about=Explain what Perl code does in plain English
# CLAM-WIT: usage=Input: { code: "my @sorted = sort { $a <=> $b } @unsorted;" } Output: { explanation: "This sorts the array numerically in ascending order." }
# CLAM-WIT: hint=perl_explain, explain code, plain English, code reading
# CLAM-WIT: author=CLAM
# CLAM-WIT: license=Artistic-2.0
package AI::Clam::Wits::Perl::Explain;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'perl_explain',
        description => 'Explain what Perl code does in plain English',
        parameters  => {
            type       => 'object',
            properties => {
                code => { type => 'string', description => 'Perl code to explain' },
            },
            required => ['code'],
        },
        execute => sub {
            my ($args) = @_;
            my $code = $args->{code} // '';

            return { explanation => "No code provided" } unless $code;

            my @explanations;

            if ($code =~ /\bmy\s+\(\s*\)/) {
                push @explanations, "Declares an empty list of lexical variables.";
            }
            if ($code =~ /\bmy\s+\$.*=\s*_\w*\b/) {
                push @explanations, "Extracts arguments from @_.";
            }
            if ($code =~ /\bsort\s*\{[^}]*\}\s*\@/) {
                push @explanations, "Sorts an array with a custom comparison function.";
            }
            if ($code =~ /\bmap\s*\{[^}]*\}\s*\@/) {
                push @explanations, "Transforms each element of an array.";
            }
            if ($code =~ /\bgrep\s*\{[^}]*\}\s*\@/) {
                push @explanations, "Filters elements from an array.";
            }
            if ($code =~ /\beval\s*\{/) {
                push @explanations, "Evaluates code in a block, catching errors.";
            }
            if ($code =~ /\buse\s+autodie/) {
                push @explanations, "Automatically dies on file operation failures.";
            }
            if ($code =~ /\bwantarray\b/) {
                push @explanations, "Checks if function was called in list context.";
            }
            if ($code =~ /\b(?:fork|waitpid)\b/) {
                push @explanations, "Uses process forking for parallel execution.";
            }
            if ($code =~ /\btie\b/) {
                push @explanations, "Binds a variable to a class for special behavior.";
            }

            if (@explanations) {
                return { explanation => join(" ", @explanations) };
            }

            return { explanation => "This code performs some Perl operations. Please describe what you want to understand." };
        },
    );
}

1;
