package Clank::Exec;
use strict;
use warnings;
use POSIX ':sys_wait_h';
use Exporter 'import';

our @EXPORT_OK = qw(exec_cmd);

my $MAX_LINES = 2000;
my $MAX_BYTES = 50 * 1024;

# Run a command in a child process with process-group isolation and timeout.
#
# Returns: { stdout, stderr, exit_code, timed_out, full_output_file }
# All fields are defined. stdout/stderr are strings (may be empty).
# On fork error, returns { error => "...", isError => 1 }.
sub exec_cmd {
    my (%opts) = @_;
    my $cmd     = $opts{command};       # string or arrayref
    my $input   = $opts{input} // '';    # optional stdin content
    my $timeout = $opts{timeout};       # seconds, undef = no timeout
    my $max_lines = $opts{max_lines} // $MAX_LINES;
    my $max_bytes = $opts{max_bytes} // $MAX_BYTES;

    my @cmd = ref $cmd eq 'ARRAY' ? @$cmd : ('bash', '-c', $cmd);

    require File::Temp;
    my ($out_fh,  $out_file)  = File::Temp::tempfile(SUFFIX => '.out', UNLINK => 0); close $out_fh;
    my ($err_fh,  $err_file)  = File::Temp::tempfile(SUFFIX => '.err', UNLINK => 0); close $err_fh;
    my ($meta_fh, $meta_file) = File::Temp::tempfile(SUFFIX => '.status', UNLINK => 0); close $meta_fh;

    my $pid = fork();
    return { error => "fork: $!", isError => 1 } unless defined $pid;

    if ($pid == 0) {
        eval { POSIX::setsid() };

        if (length $input) {
            open STDIN, '|-', @cmd or exit 127;
            print STDIN $input;
            close STDIN;
            my $rc = $? >> 8;
            if (open my $mfh, '>', $meta_file) { print {$mfh} $rc // -1; close $mfh }
            exit(($rc >> 8) & 0xff);
        } else {
            open STDOUT, '>', $out_file or exit 127;
            open STDERR, '>', $err_file or exit 127;
            open STDIN,  '<', '/dev/null';
            my $rc = system(@cmd);
            if (open my $mfh, '>', $meta_file) { print {$mfh} $rc // -1; close $mfh }
            exit(($rc >> 8) & 0xff);
        }
    }

    my ($timed_out, $status) = (0, undef);
    local $SIG{ALRM} = sub { $timed_out = 1; kill 9, -$pid; kill 9, $pid } if $timeout;
    alarm($timeout) if $timeout;
    while (!defined(waitpid($pid, 0))) { last if $timed_out }
    alarm(0) if $timeout;

    my ($stdout, $stderr) = (_slurp($out_file), _slurp($err_file));
    my $raw = _read_status($meta_file);
    unlink $out_file, $err_file, $meta_file;

    if (!defined $raw) {
        if ($timed_out) {
            return { stdout => '', stderr => '', exit_code => -1, timed_out => 1,
                     error => "timed out after ${timeout}s" };
        }
        return { stdout => '', stderr => '', exit_code => -1, timed_out => 0,
                 error => 'command did not report a status (killed before completion?)' };
    }
    if ($raw < 0) {
        return { stdout => '', stderr => '', exit_code => -1, timed_out => 0,
                 error => 'failed to start command: exec error' };
    }

    my $exit = WIFEXITED($raw) ? WEXITSTATUS($raw) : 128 + WTERMSIG($raw);
    my $killed_by_signal = !WIFEXITED($raw);

    return { stdout => $stdout, stderr => $stderr, exit_code => $exit,
             timed_out => ($timed_out && $killed_by_signal && WTERMSIG($raw) == 9) ? 1 : 0 };
}

sub _slurp { my ($f)=@_; open my $fh,'<',$f or return ''; local $/; <$fh> // ''; }

sub _read_status {
    my ($f) = @_;
    open my $fh, '<', $f or return undef;
    local $/; my $v = <$fh>; close $fh;
    return (defined $v && $v =~ /^\s*(-?\d+)\s*$/) ? 0 + $v : undef;
}

1;
