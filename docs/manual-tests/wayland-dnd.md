# Wayland drag and drop (E01.F04.S03.T03)

Run on GNOME (Mutter) and KDE Plasma (KWin) sessions, with zigguro on
Wayland (`ZG_PLATFORM=wayland`).

- [ ] Drag one file from GNOME Files into the agent prompt: the drop
      inserts its path. Repeat with three files.
- [ ] Drag a file with spaces and non-ASCII characters in its name from
      Dolphin: the path is decoded correctly.
- [ ] Drag text selected in a browser into the editor: the text is
      inserted.
- [ ] Hover a drag over a window that refuses it: the cursor shows
      "not allowed" and dropping does nothing.
- [ ] Drag a file from zigguro's tree into GNOME Files: the file is
      copied, and zigguro gets `source_finished` with copy.
- [ ] Drag with Shift held (move) into Dolphin: `source_finished`
      reports move.
- [ ] Press Esc during a drag out of zigguro: `source_finished` reports
      no action.
- [ ] Drag a tab from one zigguro window to another: the tab moves,
      and other applications do not offer to accept it.
- [ ] Drop a 50 MB text selection: the UI stays responsive while it
      transfers.
