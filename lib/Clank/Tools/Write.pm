package Clank::Tools::Write;
use strict; use warnings;
use parent 'Clank::Tool';
# Pi-parity write tool: create/overwrite file, auto-create parent dirs.

sub new {
    my ($class, %o) = @_;
    return $class->SUPER::new(
        name => 'write',
        description => "Write content to a file. Creates the file if it doesn't exist, overwrites if it does. Automatically creates parent directories.",
        parameters => {
            type => 'object',
            properties => {
                path    => { type => 'string', description => 'Path to the file to write (relative or absolute)' },
                content => { type => 'string', description => 'Content to write to the file' },
            },
            required => ['path','content'],
        },
    );
}

sub execute {
    my ($self, $a) = @_;
    my $path    = $a->{path}    or return err('path is required');
    my $content = $a->{content};
    return err('content is required (may be empty string)') unless defined $content;

    if ($path =~ m{^(.*)/[^/]+$} && length $1) {
        my $dir = $1;
        make_path($dir) or return err("mkdir $dir failed");
    }
    open my $fh, '>:raw', $path or return err("open $path: $!");
    print {$fh} $content; close $fh;
    return { output => "Successfully wrote " . length($content) . " bytes to $path", isError => 0 };
}

sub make_path { # mkdir -p
    my ($dir) = @_;
    return 1 if -d $dir;
    for my $i (1 .. length($dir)) {
        next unless substr($dir, $i-1, 1) eq '/' || $i == length($dir);
        my $prefix = substr($dir, 0, $i);
        $prefix =~ s{/+$}{};
        next if $prefix eq '' || -d $prefix;
        mkdir $prefix or return 0 unless -e $prefix;
    }
    return -d $dir;
}

sub err { my ($m)=@_; return { output => "error: $m", isError => 1 }; }
1;
