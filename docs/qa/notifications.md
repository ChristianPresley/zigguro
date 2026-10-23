# Agent notifications: manual QA

Run these checks for E13.F01.S03.T02 (Linux) and E13.F01.S03.T03 (Windows) before a release. The automated tests cover the D-Bus marshalling, the struct layout and the click routing. These checks cover the real desktops.

Setup for every platform: start zigguro and open a workspace. Start a run that will ask a question, for example `Ask me which branch to use, then stop.` Start a second run that completes.

## Linux

Run each check on GNOME (Wayland), KDE Plasma (Wayland) and one X11 session (for example Xfce).

- [ ] With the zigguro window focused and Mission Control showing the run, the question produces no OS notification and no toast.
- [ ] With the window focused but the run scrolled out of view, a toast appears and no OS notification.
- [ ] With another app focused, an OS notification appears titled "<run> needs input", with urgency critical (it stays on screen).
- [ ] Clicking the notification body raises zigguro on Wayland without a "zigguro is ready" banner (the xdg-activation token is honoured), and the run's peek panel opens.
- [ ] A permission question ("Allow ...?") shows Open and Deny buttons. Deny denies the request.
- [ ] A finished run replaces its own "needs input" notification within 10 s instead of stacking a second one.
- [ ] A workflow with many workers finishing within seconds shows one "N/M done" notification.
- [ ] Do Not Disturb (`agents.notifications.dnd`) suppresses everything, and turning it off restores notifications.
- [ ] With no notification daemon (for example `pkill mako` on a bare compositor), zigguro logs "no notification daemon" once and toasts still reach the notification center.

## Windows

Run each check on Windows 10 and Windows 11.

- [ ] A zigguro icon appears in the notification area on start and disappears on exit (no ghost icon left behind).
- [ ] With another app focused, a balloon or toast appears with the run's title and question. Errors use the error icon.
- [ ] Clicking it raises zigguro on the run's peek panel.
- [ ] With Focus Assist (Windows 10) or Do Not Disturb (Windows 11) on, no balloon pops up (quiet time is respected), and the notification center inside zigguro still lists the entry.
- [ ] Titles over 63 characters and bodies over 255 characters end in "…", and emoji sequences are not cut in half.
- [ ] After restarting Explorer (`taskkill /f /im explorer.exe`, then `start explorer`), the next notification re-adds the icon and shows.
