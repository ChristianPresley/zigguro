# Wayland cursors (E01.F04.S02.T04)

Run zigguro on Wayland (`ZG_PLATFORM=wayland`) at 100 %, 150 % and
200 % scaling for each compositor below.

GNOME (Mutter) and KDE Plasma (KWin), cursor-shape-v1:

- [ ] The arrow shows over the window; the I-beam over the editor text;
      the hand over links and buttons that use it.
- [ ] Resize cursors show over the window edges (CSD on GNOME).
- [ ] Changing the system cursor theme or size in Settings applies to
      zigguro at once, as in other apps.

Weston (no cursor-shape, Xcursor theme fallback):

- [ ] Start with `XCURSOR_THEME=Adwaita XCURSOR_SIZE=24`: the arrow
      matches Weston's own cursor and is sharp at every scale.
- [ ] The hotspot is right: clicking a 1 px line with the arrow tip or
      the I-beam centre hits it.
- [ ] A busy task shows the animated `wait`/`progress` cursor; it
      animates while over the window and stops when the pointer leaves
      (`top` shows zigguro idle with the pointer elsewhere).
- [ ] A theme without a shape (for example `XCURSOR_THEME=redglass`)
      shows the default arrow instead of nothing.
