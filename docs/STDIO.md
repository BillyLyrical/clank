# Stdio Handler Type — Process-Isolated Code Execution

Status: design. Explores options, dangers, and opportunities for executing
untrusted code via stdio subprocess boundaries.

---

## 1. The Problem

Clank is a coding harness. The LLM generates code; the harness runs it.
Different code has different trust levels:

| Code | Trust | Current isolation |
|------|-------|-------------------|
| Built-in tools (read, bash, edit, write) | Full | Bash: fork+setsid+alarm. Others: in-process |
| Installed wits (cpanm) | High | eval{} around require. No process boundary |
| User-provided wits (local) | Medium | Same as installed wits |
| LLM-generated Perl code | Low | **None** — psh_eval runs in parent process |
| LLM-generated shell commands | Low | Bash tool: fork+setsid (decent) |

The gap: when the LLM writes Perl code (via psh_eval, or future code
execution tools), it runs in the same process as the harness. A segfault,
infinite loop, or malicious `system()` call hits the harness directly.

The Bash tool already solves this for shell commands — it forks, setsid,
runs in a child process group, captures output via temp files, and kills
the group on timeout. The question is: how do we provide the same isolation
for arbitrary code execution?

---

## 2. Current State

### 2.1 What already works

**Bash tool** (`lib/Clank/Tools/Bash.pm`):
- `fork()` + `POSIX::setsid()` — child gets its own process group
- `system('bash', '-c', $cmd)` — command runs in child
- stdout/stderr captured via temp files (not pipes)
- `alarm()` + `kill -9, -$pid` — kills entire group on timeout
- Decodes exit status via `WIFEXITED`/`WEXITSTATUS`

This is solid isolation. The child can crash, hang, or misbehave without
affecting the parent. The temp-file IPC avoids pipe deadlock entirely.

**Psh::Eval** (`wits/psh/lib/Clank/Wits/Psh/Eval.pm`):
- Runs Perl code via `eval { ... }` in the parent process
- Shell commands via backticks (`` `$cmd 2>&1` ``)
- Syntax check via `` `perl -c -e '...'` `` (subprocess, but no isolation)
- **No process isolation at all** — a segfault in eval'd code kills the harness

### 2.2 What's missing

- No way to execute arbitrary Perl code in a subprocess
- No streaming stdin/stdout IPC (everything uses temp files or backticks)
- No resource limits (CPU, memory, wall time) beyond alarm()
- No filesystem sandboxing (code can read/write anything the process can)
- No network sandboxing (code can make HTTP requests, open sockets)

---

## 3. Design Options

### Option A: Long-Lived REPL Subprocess

Spawn a child Perl process that stays alive across multiple code executions.
The parent sends code via stdin, reads output via stdout.

```
Parent                          Child (perl -e 'REPL loop')
  │                                │
  ├──── "print 2+2\n" ──────────► │
  │                                │ eval, print result
  │ ◄──── "4\n" ─────────────────┤
  │                                │
  ├──── "my $x = 42\n" ─────────► │
  │ ◄──── "ok\n" ────────────────┤
  │                                │
  ├──── "print $x * 2\n" ───────► │
  │ ◄──── "84\n" ────────────────┤
```

**Pros:**
- State persists across executions (variables, subs, loaded modules)
- Amortized fork cost — one process, many executions
- Familiar model (Python REPL, irb, node)

**Cons:**
- State leaks between executions (feature or bug, depending on use case)
- Process lifetime management — when to kill the child?
- stdin/stdout protocol complexity (need delimiters, error signaling)
- Child crash kills the session — need restart logic
- Harder to sandbox (child has persistent state to protect)

### Option B: Per-Execution Spawn

Spawn a new child process for each code execution. Send code via stdin,
read output via stdout, reap the process.

```
Parent                          Child (perl -e '...')
  │                                │
  ├──── "print 2+2" ────────────► │ fork, exec
  │ ◄──── "4\n" ─────────────────┤ exit(0)
  │           (reap)              │
  │                                │
  ├──── "my $x = 42; print $x" ─► │ fork, exec (new process)
  │ ◄──── "42\n" ────────────────┤ exit(0)
  │           (reap)              │
```

**Pros:**
- Clean isolation — each execution is independent
- No state leakage between executions
- Simple crash handling — child dies, parent gets exit status
- Easy to sandbox (no persistent state to protect)
- Matches the Bash tool's model

**Cons:**
- No state persistence (each execution starts fresh)
- Fork overhead per execution (mitigated by vfork/clone on Linux)
- Still need stdin/stdout protocol for code delivery

### Option C: Wit Handler Type (Architectural)

Add a new handler type to the wit API alongside `tool`, `command`, and
`bus`. Wits register stdio handlers that auto-spawn child processes.

```perl
# In a wit's register():
$api->register_handler(
    name    => 'perl_exec',
    type    => 'stdio',          # new handler type
    command => ['perl', '-e'],   # child command
    timeout => 30,
    schema  => { ... },          # OpenAI tool schema
    execute => sub {
        my ($code) = @_;
        # Return code to send via stdin; handler captures stdout
        return $code;
    },
);
```

The framework handles:
- Fork + exec of the child command
- Sending code via stdin (with delimiter)
- Capturing stdout/stderr
- Timeout enforcement
- Exit status decoding

**Pros:**
- Wits don't implement fork/exec/IPC — framework handles it
- Consistent isolation model across all stdio-based wits
- Composable — any language with a stdin/stdout REPL works
- Clean separation: wit defines *what* to run, framework handles *how*

**Cons:**
- Framework complexity — new abstraction in the wit API
- Protocol design — stdin/stdout framing, error signaling
- Less flexible than raw fork/exec for edge cases
- Requires changes to Wit::API, PluginManager, Tool dispatch

### Option D: Replace Bash Tool Internals

Rework the Bash tool's execution model to use IPC::Open3 (streaming pipes)
instead of temp files, and generalize it into a reusable `exec_stdio`
utility.

```perl
# lib/Clank/Exec.pm
sub exec_stdio {
    my (%opts) = @_;
    my $cmd    = $opts{command};  # arrayref
    my $input  = $opts{input};
    my $timeout = $opts{timeout} // 30;

    my ($child_out, $child_in, $child_err);
    my $pid = open3($child_in, $child_out, $child_err, @$cmd);

    print $child_in $input;
    close $child_in;

    # Read with timeout, kill on alarm
    ...
}
```

**Pros:**
- Streaming IPC (no temp files)
- Reusable across bash, perl, python, any language
- Simpler than temp-file approach

**Cons:**
- Pipe deadlock risk (need non-blocking reads or select loop)
- More complex than temp files
- Still doesn't provide the long-lived REPL model
- Changes the existing Bash tool (regression risk)

---

## 4. Dangers

### 4.1 Sandbox Escape

Process isolation ≠ sandbox isolation. A child process with the same UID
can:
- Read/write any file the parent can
- Open network connections
- Spawn grandchild processes
- Access the SQLite database directly
- Send signals to the parent (`kill(getppid(), ...)`)

**Mitigation:** Process isolation buys you crash isolation, not security
isolation. For true sandboxing you need:
- `chroot` / namespaces (Linux)
- `pledge` / `unveil` (OpenBSD)
- `seccomp` filters (Linux)
- Container isolation (Docker, podman)
- `taint` mode (Perl's built-in, but weak)

Clank should be honest about what process isolation provides: crash
protection, not security. Document this clearly.

### 4.2 Resource Exhaustion

A child process can:
- Fork bomb (exponential process creation)
- Allocate unbounded memory (`my @big = (1) x (2**32)`)
- Spin in an infinite loop
- Open many file descriptors
- Fill disk with output

**Mitigation:**
- `setsid()` + process group kill (already in Bash tool)
- `ulimit` in the child before exec
- `alarm()` for wall-time limits
- Output size cap (already in Bash tool: 50KB / 2000 lines)
- Consider `Resource::Limit` or `BSD::Resource` for memory limits

### 4.3 Pipe Deadlock (if using IPC::Open3)

If the child writes enough to fill the OS pipe buffer (~64KB on Linux)
before the parent reads, the child blocks on write while the parent
blocks on read. Classic deadlock.

**Mitigation:**
- Use `select()` or `IO::Poll` for non-blocking reads
- Read stdout and stderr in separate threads or via `fork`
- Or: use temp files (current Bash approach) — no deadlock possible
- Or: use `open2()` which only captures stdout (simpler, no stderr mixing)

### 4.4 Signal Interference

`alarm()` is process-global. If a stdio handler sets an alarm and a
child process also uses `alarm()` or `eval` with timeouts, they collide.

**Mitigation:**
- Use `Time::HiRes::ualarm` with careful local scope
- Child processes get their own alarm scope (fork inherits, but child
  can reset)
- The Bash tool's approach (alarm in parent, kill child group) is correct

### 4.5 State Leaking (REPL Model)

If using a long-lived REPL subprocess, code from one execution can
affect the next:
- Variables persist
- Loaded modules persist
- Modified global state persists
- File handles may leak

**Mitigation:**
- Document that state persists (it's a feature for interactive use)
- Provide a "reset" command that restarts the child
- For sandboxed execution, prefer per-execution spawn (Option B)

### 4.6 Zombie Processes

If the parent dies without reaping children, zombies accumulate.

**Mitigation:**
- `$SIG{CHLD} = 'IGNORE'` in the parent (auto-reaps)
- Or: explicit `waitpid()` in the parent's cleanup path
- The Bash tool already handles this with `waitpid($pid, 0)` in a loop
- For daemon mode (clankd), SIGCHLD handling is critical

---

## 5. Opportunities

### 5.1 Safe Perl Execution

The biggest win: execute arbitrary Perl code without risking the harness.
Use cases:
- LLM-generated Perl scripts
- User-provided one-off scripts
- Testing code before applying it
- Sandboxed library exploration

### 5.2 Multi-Language Support

A stdio handler is language-agnostic. Any language with a stdin/stdout
REPL works:
- `perl -e 'while(<STDIN>){eval; print $@ if $@}'`
- `python3 -c '...'`
- `node -e '...'`
- `lua -e '...'`
- `ruby -e '...'`

The framework spawns the child, sends code, captures output. The wit
just specifies the command.

### 5.3 Streaming Code Execution

With IPC::Open3 (or temp files), the harness can:
- Send code incrementally
- Read output as it's produced
- Interleave with other tool calls
- Support interactive REPLs (though this complicates the protocol)

### 5.4 Resource-Bounded Execution

Process isolation enables resource limits that aren't possible in-process:
- Wall-clock timeout (alarm)
- CPU time limit (ulimit -t)
- Memory limit (ulimit -v)
- File size limit (ulimit -f)
- Process count limit (ulimit -u)

### 5.5 Crystallization Safety

The Crystallizer turns LLM solutions into deterministic Perl rules.
Process-isolated execution means:
- Test crystallized rules safely before promoting them
- Run user-contributed rules in isolation
- A bad crystallized rule can't corrupt the world model

### 5.6 Subagent Isolation

Currently, subagents run in-process (Loop.pm spawn). A stdio handler
could spawn subagents as child processes, giving them:
- True process isolation
- Independent memory space
- Clean teardown on failure
- Resource limits

---

## 6. Recommendations

### 6.1 Short Term: Per-Execution Spawn (Option B + D)

Build a reusable `Clank::Exec` module that generalizes the Bash tool's
fork+setsid+alarm pattern:

```perl
# lib/Clank/Exec.pm
sub exec_stdin {
    my (%opts) = @_;
    # command, input, timeout, max_output
    # Returns: { stdout, stderr, exit_code, timed_out }
}
```

Then:
- Refactor `Clank::Tools::Bash` to use `Clank::Exec`
- Add a `psh_sandbox` tool that uses `Clank::Exec` with `perl -e`
- Both get the same isolation model (fork+setsid+alarm+temp files)

### 6.2 Medium Term: Wit Handler Type (Option C)

If multiple wits need stdio-based execution, add `register_handler`
to the wit API. This is the architectural option — clean but requires
more framework work.

### 6.3 Long Term: REPL Subprocess (Option A)

If the use case demands persistent state (interactive Perl exploration,
long-running computations), implement the long-lived REPL subprocess.
This is the most complex option but enables the richest interaction.

### 6.4 What NOT to Do

- **Don't use IPC::Open3 for streaming** unless you need it. Temp files
  are simpler, deadlock-free, and the Bash tool proves the pattern works.
- **Don't promise security isolation.** Process isolation = crash isolation.
  For true sandboxing, document that users need chroot/seccomp/containers.
- **Don't over-engineer.** Start with Option B (per-execution spawn using
  the existing Bash tool pattern). It solves the immediate problem: safe
  Perl execution without harness corruption.

---

## 7. Open Questions

1. **Protocol framing**: How does the parent delimit code chunks sent to a
   long-lived REPL child? Options: EOF-on-stdin, magic delimiter, length prefix.

2. **Error signaling**: How does the child communicate errors vs. normal
   output? Options: exit code, stderr, structured JSON on stdout.

3. **Taint mode**: Should sandboxed Perl execution use `-T` (taint mode)?
   It's the built-in Perl sandbox, but it has limitations (can't chdir,
   must clean PATH, etc.).

4. **Resource limits**: Which limits should be defaults? Which should be
   configurable per-wit?

5. **Repl state persistence**: If we do Option A, should the REPL state
   survive across tool calls within a session? Or reset per prompt?
