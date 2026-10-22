# Screen reader test plan (E04.F09)

Automated tests cover the semantic tree (`a11y/tree_test.zig`), the UI
Automation providers against a fake `Api` (`a11y/uia_test.zig`) and the
AT-SPI2 bridge against a private `dbus-daemon` (`a11y/atspi/atspi_test.zig`).
What only a real screen reader shows is checked by hand with this list.
Record the date, OS build and reader version next to each pass.

## Windows: Narrator, then NVDA

1. Build main and start `zigguro` (welcome view), then `zigguro FILE`.
2. Start Narrator (Ctrl+Win+Enter). Alt+Tab to zigguro: Narrator says the
   window title.
3. Tab through the toolbar: each button is read with its name; icon-only
   buttons are read by their tooltip text.
4. Toggle a checkbox with Space: Narrator says "checked" / "not checked".
5. In the Explorer tree, arrow down and Right/Left: rows are read with
   "expanded" / "collapsed" and "N of M".
6. Show a toast (save a file): Narrator reads it without moving focus.
7. Open Accessibility Insights for Windows, inspect the window: no errors
   in FastPass; element names match the UI; Invoke on a button works.

## Linux: Orca on GNOME Wayland, then X11

1. Turn on the screen reader (Super+Alt+S) so `org.a11y.Status` is
   enabled, then start `zigguro`.
2. `busctl --user call org.a11y.Bus /org/a11y/bus org.a11y.Bus GetAddress`
   returns an address; Accerciser (if installed) lists `zigguro` under the
   desktop with one frame per window.
3. Repeat steps 3 to 6 of the Windows list with Orca.
4. Orca's flat review (KP_7/8/9) reads the workbench regions in order.
5. Turn the screen reader off: zigguro keeps running and Orca no longer
   receives its events.

## Known gaps

- Text boxes report their text but no caret or selection yet, and
  character extents are the box's.
- Wayland gives no window position, so AT-SPI screen coordinates are window
  coordinates there.
- Tables expose rows and cells but not the `Table` interface.
