package AI::Clam::Tools::Bash;
use strict; use warnings;
use parent 'AI::Clam::Tool';
use POSIX ':sys_wait_h';
# Pi-parity bash tool: run in cwd, capture stdout+stderr, tail-truncate to
# last 2000 lines / 50KB (full output spilled to a temp file), optional timeout.

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
    my $cmd     = $a->{command} or return err('command is required');
    my $timeout = $a->{timeout};

    require File::Temp;
    # NOTE: File::Temp->new returns only a fh in list context — use tempfile() for (fh, name)
    my ($out_fh,  $out_file)  = File::Temp::tempfile(SUFFIX => '.out', UNLINK => 0); close $out_fh;
    my ($err_fh,  $err_file)  = File::Temp::tempfile(SUFFIX => '.err', UNLINK => 0); close $err_fh;
    my ($meta_fh, $meta_file) = File::Temp::tempfile(SUFFIX => '.status', UNLINK => 0); close $meta_fh;

    my $pid = fork();
    return err("fork: $!") unless defined $pid;
    if ($pid == 0) {
        # Child: new session so the parent can kill the whole process group on
        # timeout. Run via system() — this perl build's waitpid returns corrupt
        # status values, but system() reports correctly. Write the raw status to
        # $meta_file for the parent (our own exit code is not trustworthy here).
        eval { POSIX::setsid() };
        open STDOUT, '>', $out_file or exit 127;
        open STDERR, '>', $err_file or exit 127;
        open STDIN,  '<', '/dev/null';
        my $rc = system('bash', '-c', $cmd);
        if (open my $mfh, '>', $meta_file) { print {$mfh} $rc // -1; close $mfh }
        exit(($rc >> 8) & 0xff);
    }

    # Parent: reap with a BLOCKING waitpid — its return value is unreliable in this
    # build, so it only serves as "child has exited". alarm() enforces the timeout;
    # the handler kills the whole process group. The local must outlive the wait
    # loop (scoping it to an inner block would restore the default ALRM action).
    my ($timed_out, $status) = (0, undef);
    local $SIG{ALRM} = sub { $timed_out = 1; kill 9, -$pid; kill 9, $pid } if $timeout;
    alarm($timeout) if $timeout;
    while (!defined(waitpid($pid, 0))) { last if $timed_out }
    alarm(0) if $timeout;

    my ($out, $err) = (slurp($out_file), slurp($err_file));
    my $raw = read_status($meta_file);
    unlink $out_file, $err_file, $meta_file;

    # Decode the raw wait status written by the child.
    if (!defined $raw) {
        return err("timed out after ${timeout}s: $cmd") if $timed_out;
        return err('command did not report a status (killed before completion?)');
    }
    if ($raw < 0) {
        return err("failed to start command: exec error");
    }
    my $exit = WIFEXITED($raw) ? WEXITSTATUS($raw) : 128 + WTERMSIG($raw);
    return err("timed out after ${timeout}s: $cmd")
        if $timed_out && !WIFEXITED($raw) && WTERMSIG($raw) == 9;

    my @parts;
    push @parts, "stdout:\n$out" if length $out;
    push @parts, "stderr:\n$err" if length $err;
    my $combined = @parts ? join("\n", @parts) : '(no output)';

    # tail-truncate: last MAX_LINES lines or MAX_BYTES (whichever hit first)
    my @lines = split /\n/, $combined, -1;
    my ($trunc_file) = '';
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
    my $sig_note = WIFEXITED($raw) ? '' : " (killed by signal " . WTERMSIG($raw) . ")";
    # Spill path goes last with nothing after it so callers can extract it with
    # /full output: (\S+)/.
    my $tail = "\n[exit code: $exit]$sig_note" . ($trunc_file ? "\nfull output: $trunc_file" : '');
    return { output => $combined . $tail, isError => 0 };
}

sub slurp { my ($f)=@_; open my $fh,'<',$f or return ''; local $/; <$fh> // ''; }

# Raw wait status the child wrote (a non-negative integer), or undef.
sub read_status {
    my ($f) = @_;
    open my $fh, '<', $f or return undef;
    local $/; my $v = <$fh>; close $fh;
    return (defined $v && $v =~ /^\s*(-?\d+)\s*$/) ? 0 + $1 : undef;
}

sub err   { my ($m)=@_; return { output => "error: $m", isError => 1 }; }
1;
