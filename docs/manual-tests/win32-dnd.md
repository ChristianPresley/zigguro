# Win32 drag and drop (E01.F02.S04.T02)

Run on Windows 10 and Windows 11, at 100 % and 150 % scaling.

- [ ] Drag one file from Explorer into the agent prompt: the drop
      inserts its path. Repeat with three files.
- [ ] Drag a file with spaces and non-ASCII characters in its name, and
      one from a network share (`\\server\share`): the paths are decoded
      correctly.
- [ ] Drag text selected in Edge or Chrome into the editor: the text is
      inserted. Repeat from Word: the text arrives, not the HTML markup.
- [ ] Hover a drag over a window that refuses it: the cursor shows
      "not allowed" and dropping does nothing.
- [ ] Hold Ctrl, Shift and Ctrl+Shift while hovering a drop zone that
      allows every action: the cursor shows copy, move and link.
- [ ] Drag a file from zigguro's tree into Explorer: the file is copied,
      and zigguro gets `source_finished` with copy. With Shift, it is
      moved and `source_finished` reports move.
- [ ] Drag text out of the editor into Notepad and into Word: the text
      lands with line breaks intact.
- [ ] Press Esc during a drag out of zigguro: `source_finished` reports
      no action.
- [ ] While dragging out of zigguro, the window keeps repainting (an
      animation or blinking caret keeps moving).
- [ ] Drag a tab from one zigguro window to another: the tab moves, and
      Explorer does not offer to accept it.
- [ ] Close a zigguro window while another application's drag hovers
      over it: nothing crashes.
