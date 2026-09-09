package Clank::Tools::Bash;
use strict; use warnings;
use parent 'Clank::Tool';
# Pi-parity bash tool: run in cwd, capture stdout+stderr, tail-truncate to
# last 2000 lines / 50KB (full output spilled to a temp file), optional timeout.
# Delegates process isolation to Clank::Exec.

use Clank::Exec qw(exec_cmd);

my $MAX_LINES = 2000;
my $MAX_BYTES = 50 * 1024;

sub new {
    my ($class, %o) = @_;
    return $class->SUPER::new(
        name => 'bash',
        description => "Execute a bash command in the current working directory. Returns stdout and stderr. Output is truncated to last 2000 lines or 50KB (whichever is hit first). If truncated, full output is saved to a temp file. Optionally provide a timeout in seconds.",
        parameters => {
            type => 'object',
            properties => {
                command => { type => 'string', description => 'Shell command to execute' },
                timeout => { type => 'number', description => 'Timeout in seconds (optional, no default timeout)' },
            },
            required => ['command'],
        },
    );
}

sub execute {
    my ($self, $a) = @_;
    my $cmd     = $a->{command} or return _err('command is required');
    my $timeout = $a->{timeout};

    my $r = exec_cmd(command => $cmd, timeout => $timeout);
    return { output => "error: $r->{error}", isError => 1 } if $r->{isError};
    return _err("timed out after ${timeout}s: $cmd") if $r->{timed_out};

    my @parts;
    push @parts, "stdout:\n$r->{stdout}" if length $r->{stdout};
    push @parts, "stderr:\n$r->{stderr}" if length $r->{stderr};
    my $combined = @parts ? join("\n", @parts) : '(no output)';

    my ($trunc_file) = '';
    my @lines = split /\n/, $combined, -1;
    if (@lines > $MAX_LINES || length($combined) > $MAX_BYTES) {
        require File::Temp;
        my ($tfh, $tfile) = File::Temp::tempfile(SUFFIX => '.full', UNLINK => 0);
        print {$tfh} $combined; close $tfh;
        $trunc_file = $tfile;
        @lines = @lines[-$MAX_LINES .. -1] if @lines > $MAX_LINES;
        my $s = join("\n", @lines);
        $s = substr($s, -$MAX_BYTES) while length($s) > $MAX_BYTES;
        $combined = "[output truncated to last " . scalar(@lines) . " lines]\n" . $s;
    }

    my $exit = $r->{exit_code};
    my $tail = "\n[exit code: $exit]" . ($trunc_file ? "\nfull output: $trunc_file" : '');
    return { output => $combined . $tail, isError => 0 };
}

sub _err { my ($m)=@_; return { output => "error: $m", isError => 1 }; }
1;
