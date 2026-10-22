# zigguro directories

`zg_config.paths.resolve` is the one authority for where zigguro keeps its
files. Other epics cite these names: `<config>`, `<data>`, `<state>`,
`<cache>` and `<managed>`.

| Kind | Linux / BSD (XDG) | Windows | macOS (later) |
|---|---|---|---|
| `<config>` | `$XDG_CONFIG_HOME/zigguro`, default `~/.config/zigguro` | `%APPDATA%\zigguro` | `~/Library/Application Support/zigguro` |
| `<data>` | `$XDG_DATA_HOME/zigguro`, default `~/.local/share/zigguro` | `%LOCALAPPDATA%\zigguro\data` | `<config>/data` |
| `<state>` | `$XDG_STATE_HOME/zigguro`, default `~/.local/state/zigguro` | `%LOCALAPPDATA%\zigguro\state` | `<config>/state` |
| `<cache>` | `$XDG_CACHE_HOME/zigguro`, default `~/.cache/zigguro` | `%LOCALAPPDATA%\zigguro\cache` | `~/Library/Caches/zigguro` |
| `<managed>` | `/etc/zigguro` | `%ProgramData%\zigguro` (absent if unset) | `/Library/Application Support/zigguro` |

Well-known files:

| File | Path |
|---|---|
| User settings | `<config>/settings.zon` |
| User keybindings | `<config>/keybindings.zon` |
| Installed extensions | `<data>/extensions/` |
| Locked (policy) settings | `<managed>/settings.zon` |

## Rules

- A relative or empty XDG variable is ignored, as the XDG Base Directory
  specification requires, and the default is used.
- On Windows, a missing `%APPDATA%` or `%LOCALAPPDATA%` falls back to
  `%USERPROFILE%\AppData\Roaming` and `...\Local`.
- `ZIGGURO_CONFIG_DIR`, `ZIGGURO_DATA_DIR`, `ZIGGURO_STATE_DIR` and
  `ZIGGURO_CACHE_DIR` override one directory each. They must be absolute;
  a relative override is ignored.
- **Portable mode:** when a directory named `zigguro-data` sits next to the
  executable, every kind lives under it (`zigguro-data/{config,data,state,cache}`)
  and `portable` is true. Overrides still win.
- `resolve` reads only the environment map it is given and allocates only
  in the caller's arena. It never creates directories: writers create them
  on first write.
- Missing `HOME` (or `USERPROFILE` on Windows) is `error.NoHomeDirectory`.
