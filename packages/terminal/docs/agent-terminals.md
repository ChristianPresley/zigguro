# Agent terminals

An agent's shell commands (the `run_command`, `command_output` and
`kill_command` tools) run in terminals you can watch. Each agent session
gets its own terminal in the **Agents** section of the terminal panel. The
shell lives on between commands, so `cd`, exported variables and activated
environments carry over, the way they do when you type the commands
yourself.

Setting: `terminal.agent.visibleTerminals` (on by default). It takes
effect when the agent starts.

## How a command runs

1. The agent's terminal opens with shell integration loaded, whatever
   `terminal.integrated.shellIntegration.enabled` says. Integration is how
   zigguro knows where a command's output starts and ends and what exit
   code it returned.
2. zigguro waits for an empty prompt. If the terminal stays busy for 5 s
   (a background command still runs there, or you are typing in it), or
   its shell has ended, the agent moves to a new terminal in the same
   folder.
3. The command is typed at the prompt as a bracketed paste when the shell
   asked for one, so a command that spans several lines runs as one.
   Control characters are removed. A command with a folder runs as
   `cd -- '<folder>' && <command>` (bash, zsh, fish), `cd /d "<folder>" &&
   <command>` (cmd) or `Set-Location -LiteralPath '<folder>'; if ($?) {
   <command> }` (PowerShell).
4. The command block the shell reports next belongs to the command. It is
   marked as the agent's. Its output reaches the agent line by line as
   rows finish: wrapped rows are joined, trailing blanks are trimmed, and
   output that ends without a newline is kept. A job keeps at most
   200,000 lines.
5. The block's exit code is the command's. If the shell reports no exit
   code, the command fails with a note saying so.

## Stopping a command

`kill_command`, and canceling the agent's turn, type Ctrl+C. If the
command still runs 2 s later, the terminal's shell is ended along with
everything it started, and the next command opens a new terminal. Closing
an agent's terminal yourself ends its running command as killed.

## When there is no terminal

Commands run as hidden child processes, as in `zg agent`, when:

- the setting is off;
- the shell reports no prompt within 10 s (zigguro has no integration
  script for it, or a startup file breaks it). That terminal is closed
  again.

## For developers

- `zg_terminal.agent` (packages/terminal/src/agent/run.zig) is the
  headless part: `readiness`, `commandBytes` and `Run`, which binds to a
  block and collects its lines from `BlockEvent`s.
- The app's `AgentTerminals` (apps/zigguro/src/agent/terminals.zig)
  implements zg_ai's `TerminalHost` over the workbench's terminal panels.
  Tool calls run on agent threads and reach the terminals through the UI
  thread.
- An agent terminal is saved as history only when the folder closes
  (persistent sessions); its shell is not started again.
