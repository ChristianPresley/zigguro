# X11 drag and drop (E01.F05.S03.T03)

Run on Xorg sessions (GNOME on Xorg, KDE Plasma X11 and Xfce), with
zigguro on X11 (`ZG_PLATFORM=x11`).

- [ ] Drag one file from the file manager (Nautilus, Dolphin, Thunar)
      into the agent prompt: the drop inserts its path. Repeat with
      three files.
- [ ] Drag a file with spaces and non-ASCII characters in its name: the
      path is decoded correctly.
- [ ] Drag text selected in Firefox or Chromium into the editor: the
      text is inserted.
- [ ] Hover a drag over a window that refuses it: the cursor shows
      "not allowed" and dropping does nothing.
- [ ] Drag a file from zigguro's tree into the file manager: the file
      is copied, and zigguro gets `source_finished` with copy.
- [ ] Drag out of zigguro onto a window that uses `XdndProxy` (a Qt or
      GTK application with a native file dialog open): the drop lands.
- [ ] Press Esc during a drag out of zigguro: `source_finished` reports
      no action and the pointer is released.
- [ ] Drag a tab from one zigguro window to another: the tab moves,
      and other applications do not offer to accept it.
- [ ] Drop a 50 MB text selection: the UI stays responsive while it
      transfers (INCR).
