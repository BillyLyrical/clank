# CLAM-WIT: name=TestGen
# CLAM-WIT: version=1.0.0
# CLAM-WIT: about=Generate test skeletons from function signatures
# CLAM-WIT: usage=Input: { code: "sub add { my ($a, $b) = @_; return $a + $b; }" } Output: { tests: [...], names: [...] }
# CLAM-WIT: hint=perl_test_gen, test generation, test skeleton, Test::More
# CLAM-WIT: author=CLAM
# CLAM-WIT: license=Artistic-2.0
package AI::Clam::Wits::Perl::TestGen;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;

    $api->register_tool(
        name        => 'perl_test_gen',
        description => 'Generate test skeletons from function signatures',
        parameters  => {
            type       => 'object',
            properties => {
                code => { type => 'string', description => 'Perl code with subroutines' },
            },
            required => ['code'],
        },
        execute => sub {
            my ($args) = @_;
            my $code = $args->{code} // '';

            return { test => '', error => "No code provided" } unless $code;

            my @tests;

            while ($code =~ /^sub\s+(\w+)\s*(?:\{|\(([^)]*)\)\s*\{)/gm) {
                my $name = $1;
                my $args = $2 // '';

                my $test = "use Test::More;\n\n";
                $test .= "subtest '$name' => sub {\n";
                $test .= "    # TODO: Add test cases\n";
                $test .= "    ok(1, '$name runs without error');\n";
                $test .= "};\n\n";
                $test .= "done_testing();\n";

                push @tests, { name => $name, test => $test };
            }

            if (@tests) {
                return {
                    tests => [map { $_->{test} } @tests],
                    names => [map { $_->{name} } @tests],
                };
            }

            return { test => '', error => "No subroutines found" };
        },
    );
}

1;
