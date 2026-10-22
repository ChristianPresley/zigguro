# Manual test: Win32 file dialogs, open-URI and theme (E01.F07.S01.T03)

Modal shell dialogs and theme switches cannot be driven in CI. Run this
checklist on real Windows 10 and 11 for any change to
`packages/platform/src/win32/{dialogs,shell,theme}.zig` or to their paths in
`win32/backend.zig`. It needs an app that submits `Command.open_dialog` and
`Command.open_uri` and prints `Event.dialog_result` and
`Event.appearance_changed`.

## File dialogs

- [ ] `open_file` with filters "Zig sources" (`*.zig;*.zon`) and
  "Everything": the dialog is modal to the parent window, shows both
  filters, and returns one absolute path.
- [ ] `open_files`: Ctrl+click three files; the result holds three
  NUL-separated paths.
- [ ] `open_directory`: only folders can be picked; the result is the folder.
- [ ] `save_file` with `default_path = C:\Users\<you>\notes.md`: the dialog
  opens in that folder with `notes.md` filled in, and returns the chosen
  path.
- [ ] Cancel each kind: `cancelled = true` and no paths.
- [ ] A path with non-ASCII characters (`C:\tmp\日本語\ü.txt`) round-trips as
  UTF-8.
- [ ] Two dialogs on two windows at once both answer, with their own
  request ids.
- [ ] Close the parent window while its dialog is open: the dialog closes and
  the app exits without hanging.

## Open URI

- [ ] `https://ziglang.org/` opens in the default browser.
- [ ] `mailto:someone@example.com` opens the mail handler.
- [ ] `file:///C:/Windows/notepad.exe` is refused with `error.Unsupported`
  and nothing starts.

## Theme

- [ ] At start the app receives `appearance_changed` matching Settings >
  Personalization > Colors (light or dark, accent colour).
- [ ] Switch "Choose your app mode" between light and dark: one
  `appearance_changed` arrives and the title bar follows.
- [ ] Change the accent colour: `accent` follows (sRGB).
- [ ] Turn high contrast on and off (Left Alt+Left Shift+Print Screen):
  `contrast` follows.
- [ ] Turn off "Animation effects" (Accessibility > Visual effects):
  `reduced_motion = true`.
