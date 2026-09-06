# CLAM-WIT: name=DetectSystemCall
# CLAM-WIT: version=1.0.0
# CLAM-WIT: about=Detect system call usage
# CLAM-WIT: usage=Detect system call usage
# CLAM-WIT: hint=detect, system call, exec, backtick, open pipe
# CLAM-WIT: author=CLAM
# CLAM-WIT: license=Artistic-2.0
package Clam::Wits::Logic::Rule::DetectSystemCall;
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
