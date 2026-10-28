# Persistent terminal sessions

When the window closes, zigguro saves every terminal in the folder: its
tab and split, its name, the folder its shell was last in, and the last
1,000 lines it showed. When the folder is opened again and the terminal
panel is shown, each terminal comes back with that output (colours, links
and command blocks included) above a faint
"Restored session, saved <date> UTC" line, and a fresh shell starts below
it in the saved folder (zigguro's own folder when it no longer exists).

The running programs are not kept: the old shell ended with the window.
Restored command blocks are untrusted, so **Run Last Command Again** never
re-runs a command from a previous session. A full-screen program's screen
(vim, htop) is not saved; the shell's screen under it is. Agent terminals
come back as history only, with no shell.

Turn it off with `terminal.integrated.persistentSessions.enabled: false`;
the saved file is deleted the next time the window closes or the
terminal panel opens.

## The file

`<state>/layouts/<hash of the folder>/terminals.zgts`, beside the saved
layout. It holds each terminal's output as the escape sequences that
redraw it, deflated, with a CRC-32 at the end; a file that is truncated,
corrupt or from another version is ignored. The format is described in
`src/session/persist.zig`. It contains whatever the terminals showed,
secrets included, so it stays on this machine with the rest of zigguro's
state.
