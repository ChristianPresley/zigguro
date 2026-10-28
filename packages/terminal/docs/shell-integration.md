# Shell integration

zigguro's terminal knows where each prompt, command and its output start
and end, and how each command exited, when the shell reports it. Shells
report it with escape sequences printed from their prompt hooks. zigguro
ships scripts for bash, zsh, fish, PowerShell and cmd and loads them
automatically; other terminals' scripts that print the same sequences
work too.

## What you get

- A dot left of each prompt: green when the command succeeded, red when
  it failed, an outline while it runs or when the exit code is unknown.
- **Ctrl+Up / Ctrl+Down** (Cmd on macOS) scroll to the previous or next
  command; **Ctrl+Shift+Up / Ctrl+Shift+Down** select its output.
- Commands **Terminal: Copy Last Command**, **Copy Last Command Output**
  and **Run Last Command Again**.

Turn it off with `terminal.integrated.shellIntegration.enabled: false`
(applies to new terminals).

## The sequences

| Sequence | Meaning |
|---|---|
| `OSC 133 ; A ST` | A prompt starts here (`k=c`/`k=s`/`k=r` mark continuation, secondary and right prompts, which do not start a command). |
| `OSC 133 ; B ST` | The prompt ends; typing starts here. |
| `OSC 633 ; E ; <command line> ; <nonce> ST` | The command line about to run. `\` is written `\\`, `;` is `\x3b`, control characters are `\xNN`. |
| `OSC 133 ; C ST` | The command runs; its output starts here. |
| `OSC 133 ; D [; <exit code>] ST` | The command finished. |
| `OSC 7 ; file://<host>/<path> ST` | The working folder (percent-encoded). `OSC 9;9;"<path>"` and `OSC 1337;CurrentDir=` are read too. |
| `OSC 633 ; P ; <key>=<value> ST` | Properties: `Shell`, `IntegrationVersion`. |

`ST` is `ESC \` or `BEL`.

A command line is **trusted** only when it carries the session's nonce,
which zigguro passes to the shell in `ZIGGURO_NONCE` and the script removes
from the environment before anything else runs. Output that merely prints
an `OSC 633;E` sequence (a `cat` of a log, say) cannot forge a trusted
command line, and **Run Last Command Again** runs only trusted ones. When
no `E` arrives, the command line is read from the screen between `B` and
`C` and is untrusted.

## How the scripts are loaded

The scripts live in `packages/terminal/src/shell/scripts/`, are embedded in
the app and written on first use to
`<cache>/zigguro/shell-integration/<version>/` (`$XDG_CACHE_HOME`,
`~/.cache` or `%LOCALAPPDATA%`). Nothing in your home folder or dotfiles is
written or changed.

| Shell | How it is started |
|---|---|
| bash | `bash --init-file <dir>/zigguro.bash -i`. The script first reads what bash would have: `/etc/bash.bashrc` and `~/.bashrc`, or for a login shell (`-l` is replaced by `ZIGGURO_SHELL_LOGIN=1`) `/etc/profile` and the first of `~/.bash_profile`, `~/.bash_login`, `~/.profile`. Hooks: `PROMPT_COMMAND` (first and last entry) and `PS0`. |
| zsh | `ZDOTDIR=<dir>/zsh`; your `ZDOTDIR` is passed in `ZIGGURO_USER_ZDOTDIR`. Each shim (`.zshenv`, `.zprofile`, `.zshrc`, `.zlogin`) sources your file of the same name, then `.zshrc` (or `.zlogin` for login shells) installs `precmd`/`preexec` hooks and restores your `ZDOTDIR`. Nothing is printed during startup, so p10k's instant prompt keeps working. |
| fish | `<dir>` is put first in `XDG_DATA_DIRS` so fish loads `fish/vendor_conf.d/zigguro.fish`, which restores the variable and hooks the `fish_prompt`, `fish_preexec` and `fish_postexec` events. fish 4 prints `A`, `C` and `D` itself; the script then adds only `B`, `E` and the folder. |
| PowerShell | `-NoExit -Command ". '<dir>/zigguro.ps1'"` after your profile. The script wraps `prompt` and, with PSReadLine, `PSConsoleHostReadLine`. |
| cmd | `PROMPT` gets the marks around your prompt. cmd reports no exit codes or command lines. |

The shell is left alone when it is started to run something (`-c`, a
script path, `-Command`, `/c`, ...) or told to skip its startup files
(`--norc`, `-f`, `--no-config`, ...), and for other shells (sh, dash, nu).

### Installing by hand

Over ssh, or in a terminal zigguro did not start, source the script from
your shell's startup file, for example in `~/.bashrc`:

```sh
[ -n "${__zg_loaded:-}" ] || . /path/to/zigguro.bash
```

Without the nonce, command lines are untrusted: blocks, exit codes and
navigation work, but **Run Last Command Again** asks you to retype.

## Limits

- bash: a command kept out of the history (`HISTCONTROL=ignorespace`) has
  its command line read from the screen.
- Prompt frameworks that print after the last `PROMPT_COMMAND` /
  `precmd` hook can move the `B` mark; only the screen fallback for the
  command line depends on it.
- PowerShell and cmd have not been run on Windows yet.
