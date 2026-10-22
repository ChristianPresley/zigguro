# X11 test fixtures

- `xkb_us.bin`: replies captured from Xvfb (default `evdev`/`pc105`/`us`
  keymap) over a raw X connection: `u32` length + the `XkbGetMap` reply
  (KeyTypes, KeySyms, ModifierMap, VirtualMods, VirtualModMap), `u32`
  length + the `XkbGetNames` reply (KeyNames, VirtualModNames), then a
  count byte and each virtual modifier name as a length byte + bytes
  (from `GetAtomName`). Xvfb in CI ignores `setxkbmap`, so two-layout
  behaviour is tested by encoding `xkb/testdata/ru_us_2groups.xkb` into
  replies instead.
