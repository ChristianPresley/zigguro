# XKB keymap fixtures

Fully resolved XKB keymaps in the text format that Wayland compositors send
through `wl_keyboard.keymap`. They are generated data, dedicated to the
public domain (CC0).

They were produced with `xkbcomp -w0 -xkb` (x11-xkb-utils 7.7) from
xkb-data 2.41, using this input for each layout:

```
xkb_keymap {
  xkb_keycodes { include "evdev+aliases(<ALIASES>)" };
  xkb_types    { include "complete" };
  xkb_compat   { include "complete" };
  xkb_symbols  { include "<SYMBOLS>" };
  xkb_geometry { include "pc(pc105)" };
};
```

| File | `<SYMBOLS>` | `<ALIASES>` |
|------|-------------|-------------|
| `us.xkb` | `pc+us+inet(evdev)` | `qwerty` |
| `de.xkb` | `pc+de+inet(evdev)` | `qwertz` |
| `fr.xkb` | `pc+fr+inet(evdev)` | `azerty` |
| `ru_us_2groups.xkb` | `pc+us+ru:2+inet(evdev)+group(alt_shift_toggle)` | `qwerty` |
| `jp.xkb` | `pc+jp+inet(evdev)` | `qwerty` |

xkbcomp writes the same grammar as xkbcommon's serializer (which Mutter,
KWin and wlroots use), and it also leaves implicit key types out, so the
fixtures exercise the type-inference rules. Expected resolutions in the tests
follow the xkb-data symbol files and xkbcommon's documented rules.
