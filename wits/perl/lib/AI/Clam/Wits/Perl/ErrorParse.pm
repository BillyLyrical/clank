# CLAM-WIT: name=ErrorParse
# CLAM-WIT: version=1.0.0
# CLAM-WIT: about=Parse Perl error messages and suggest fixes
# CLAM-WIT: usage=Input: { error: "Can't call method 'foo' on unblessed reference at script.pl line 42" } Output: { type: "bless", suggestion: "...", line: 42 }
# CLAM-WIT: hint=perl_error_parse, error parsing, error messages, fix suggestions
# CLAM-WIT: author=CLAM
# CLAM-WIT: license=Artistic-2.0
package AI::Clam::Wits::Perl::ErrorParse;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'perl_error_parse',
        description => 'Parse Perl error messages and suggest fixes',
        parameters  => {
            type       => 'object',
            properties => {
                error => { type => 'string', description => 'Perl error message' },
            },
            required => ['error'],
        },
        execute => sub {
            my ($args) = @_;
            my $error = $args->{error} // '';

            return { type => 'unknown', suggestion => 'No error provided' } unless $error;

            my %patterns = (
                'Can\'t call method' => {
                    type       => 'method_call',
                    suggestion => 'Object not blessed or method not defined. Check constructor and method name.',
                },
                'Use of uninitialized value' => {
                    type       => 'uninitialized',
                    suggestion => 'Variable used before assignment. Add default value or check if defined.',
                },
                'Modification of a read-only value' => {
                    type       => 'readonly',
                    suggestion => 'Trying to modify a constant or readonly variable. Use a separate variable.',
                },
                ' subroutine.*redefined' => {
                    type       => 'redefined',
                    suggestion => 'Subroutine defined twice. Remove duplicate or rename.',
                },
                'Bareword.*not allowed' => {
                    type       => 'bareword',
                    suggestion => 'Bareword used as string. Quote it: "word" or useqw(word).',
                },
                'Missing semicolon' => {
                    type       => 'semicolon',
                    suggestion => 'Add semicolon at end of statement.',
                },
                ' syntax error' => {
                    type       => 'syntax',
                    suggestion => 'Check syntax near error location. Common: missing braces, parentheses.',
                },
                'No such file or directory' => {
                    type       => 'file_not_found',
                    suggestion => 'File or module not found. Check path and @INC.',
                },
                'Permission denied' => {
                    type       => 'permission',
                    suggestion => 'Insufficient permissions. Check file permissions or run as correct user.',
                },
                'Unterminated' => {
                    type       => 'unterminated',
                    suggestion => 'Unclosed string, regex, or block. Check matching delimiters.',
                },
            );

            for my $pattern (keys %patterns) {
                if ($error =~ /$pattern/) {
                    my $line;
                    $line = $1 if $error =~ /line (\d+)/;

                    return {
                        type       => $patterns{$pattern}{type},
                        suggestion => $patterns{$pattern}{suggestion},
                        line       => $line,
                        original   => $error,
                    };
                }
            }

            return {
                type       => 'unknown',
                suggestion => 'Check Perl documentation for this error.',
                original   => $error,
            };
        },
    );
}

1;
