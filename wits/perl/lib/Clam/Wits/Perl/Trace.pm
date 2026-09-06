# CLAM-WIT: name=Trace
# CLAM-WIT: version=1.0.0
# CLAM-WIT: about=Add trace/debug output to Perl code
# CLAM-WIT: usage=Input: { code: "sub foo { return bar(); }", level: "basic" } Output: { traced: "..." }
# CLAM-WIT: hint=perl_trace, trace, debug, warn, instrumentation
# CLAM-WIT: author=CLAM
# CLAM-WIT: license=Artistic-2.0
package Clam::Wits::Perl::Trace;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'perl_trace',
        description => 'Add trace/debug output to Perl code',
        parameters  => {
            type       => 'object',
            properties => {
                code  => { type => 'string', description => 'Perl code to trace' },
                level => { type => 'string', description => 'Trace level: basic, args, full', default => 'basic' },
            },
            required => ['code'],
        },
        execute => sub {
            my ($args) = @_;
            my $code = $args->{code} // '';
            my $level = $args->{level} // 'basic';

            return { traced => $code, error => "No code provided" } unless $code;

            my $traced = $code;

            $traced =~ s/^sub\s+(\w+)\s*\{/sub $1 {\n    warn "TRACE: $1 called" if \$ENV{CLAM_TRACE};/gm;

            if ($level eq 'args' || $level eq 'full') {
                $traced =~ s/warn "TRACE: (\w+) called"/warn "TRACE: $1 called with args: " . join(", ", \@_)/g;
            }

            if ($level eq 'full') {
                $traced =~ s/return\s+(.+?);/my \$result = $1; warn "TRACE: returning \$result"; return \$result;/g;
            }

            return { traced => $traced };
        },
    );
}

1;
