# Wayland decorations (E01.F04.S01.T02)

Run zigguro on Wayland (`ZG_PLATFORM=wayland`).

GNOME (Mutter, client-side decorations):

- [ ] Drag the title bar: the window moves. Release without moving:
      nothing else happens.
- [ ] Resize from all four edges and all four corners; the cursor shows
      the matching resize arrow over each.
- [ ] Double-click the title bar: the window maximizes; again: it
      restores. Maximized, the window has no invisible border.
- [ ] Right-click the title bar: the GNOME window menu opens at the
      pointer.
- [ ] Super+Left / Super+Right tile the window to a screen half: the
      visible edge, not the invisible margin, touches the screen edge
      and the other half.
- [ ] Drag the window to the top edge: it maximizes along the visible
      bounds.
- [ ] Minimize, maximize and close buttons in the title bar act on
      release, and a press dragged off a button does nothing.
- [ ] At 125 % and 200 % scaling the resize band stays about 8 logical
      px wide outside the window.

KDE Plasma (KWin) and Sway (server-side decorations):

- [ ] The window has the compositor's title bar and borders; zigguro
      draws none and leaves no margin.
- [ ] In KWin, setting the window to "No titlebar and frame" from the
      window menu keeps it usable.
