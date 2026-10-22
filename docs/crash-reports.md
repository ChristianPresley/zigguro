# Crash reports

zigguro and `zg` write one `.zgcrash` report per crash to a local folder. Nothing is uploaded. The format is specified in [packages/crash/docs/format.md](../packages/crash/docs/format.md); the code is in `packages/crash` (E17.F05).

## Where reports go

| OS | State directory | Reports |
|---|---|---|
| Linux | `$ZIGGURO_STATE_DIR`, else `$XDG_STATE_HOME/zigguro`, else `~/.local/state/zigguro` | `<state>/crashes/` |
| Windows | `%ZIGGURO_STATE_DIR%`, else `%LOCALAPPDATA%\zigguro` | `<state>\crashes\` |

When the crash happened while a new version was still on probation (the `boot_pending` annotation), the crash path also writes `<state>/update/boot-crashed` with the version, so the next start can roll back (E17.F04.S02).

## What a report holds

- META: product, version, channel, commit, target, optimize mode, OS version, pid, uptime and install kind.
- The exception: kind, the signal or NTSTATUS, the fault address and access (read, write, execute), the thread, PC and SP.
- The panic message, for Zig panics.
- Annotations the app set (`zg_crash.annotations`), such as the current view.
- The CPU context and the stack trace.
- Loaded modules with their ids: GNU build ids on Linux, PDB 7.0 (CodeView GUID and age) on Windows.
- 16 KiB of the crashing thread's stack above SP.
- The thread ids (with names on Linux).

The report holds no file contents, environment or command line beyond what annotations add.

## Linux coverage

Handlers for SIGSEGV, SIGILL, SIGBUS and SIGFPE (installed by `zg_crash.install`, replacing std's), SIGABRT, SIGTRAP and SIGSYS, plus the Zig panic hook. Handlers run on the signal stack, so stack overflows are reported on every thread that has one (std gives each `std.Thread` one when `signal_stack_size` is set). After writing, the process ends with the original signal.

Not covered: SIGKILL and the OOM killer, and crashes before `install` runs (std's default handler prints a trace instead).

## Windows coverage

- An unhandled-exception filter (`SetUnhandledExceptionFilter`) reports every exception nothing else handled: access violations, illegal instructions, integer division by zero, breakpoints and any other NTSTATUS (kind `windows_exception`). The process then ends with the exception code as its exit status.
- A vectored handler, added last, reacts only to `EXCEPTION_STACK_OVERFLOW`, on any thread. A thread that overflowed has almost no stack left, so it never writes the report itself.
- Every report is written by a writer thread created at install with its own 256 KiB stack. The faulting thread hands over and waits up to 10 seconds.
- First-chance exceptions that a DLL handles itself (a graphics driver's `__try`/`__except`, a vectored handler that continues) produce no report. This is why the apps turn std's own Windows segfault handler off (`.enable_segfault_handler = builtin.os.tag != .windows`): it is a vectored handler and would treat such exceptions as fatal.
- `SetErrorMode(SEM_NOGPFAULTERRORBOX)` stops the Windows Error Reporting dialog after our report; WER still records the event.
- The installing thread reserves 64 KiB for the overflow handler (`SetThreadStackGuarantee`); other threads can call `zg_crash.guardCurrentThread()` first thing.

Limits on Windows:

- **Fail-fast.** `__fastfail`, `STATUS_STACK_BUFFER_OVERRUN` (/GS failures) and heap-corruption terminations skip every user-mode handler and go straight to WER, so they leave no `.zgcrash`. To capture those, enable WER local dumps for `zigguro.exe`:
  ```
  reg add "HKLM\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps\zigguro.exe" /v DumpType /t REG_DWORD /d 1
  ```
  Minidumps then land in `%LOCALAPPDATA%\CrashDumps`.
- **Debugger attached.** The unhandled-exception filter does not run while a debugger is attached; the debugger gets the exception instead.
- `std.process.abort` exits with status 3 without raising an exception, so a plain abort leaves no report (a Zig panic still does, through the panic hook first).
- Thread names are not recorded (`GetThreadDescription` allocates).

## Testing

`zig build test-crash` spawns `packages/crash/test/crasher.zig`, built ReleaseFast and ReleaseSafe, for every crash kind and checks the report, the exit status, the module ids against the file on disk, the trace and the boot marker. On Windows it also checks a crash on a raw `CreateThread` thread, a stack overflow on a worker thread and that a handled first-chance exception leaves no report. In the cloud the Windows run uses wine:

```
zig build test-crash -Dtarget=x86_64-windows -fwine
```
