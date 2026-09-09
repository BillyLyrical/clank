# CLANK-WIT: name=DetectSystemCall
# CLANK-WIT: version=1.0.0
# CLANK-WIT: about=Detect system call usage
# CLANK-WIT: usage=Detect system call usage
# CLANK-WIT: hint=detect, system call, exec, backtick, open pipe
# CLANK-WIT: author=Clank
# CLANK-WIT: license=Artistic-2.0
package Clank::Wits::Logic::Rule::DetectSystemCall;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;
    $api->register_tool(
        name        => 'detect_system_call',
        description => 'Detect system call usage',
        parameters  => { type => 'object', properties => { text => { type => 'string' } }, required => ['text'] },
        execute     => sub {
            my ($args) = @_;
            my $text = $args->{text} // '';
            # TODO: implement classification logic
            return undef;
        },
    );
}

1;
