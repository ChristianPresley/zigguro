# Meta model entities lspgen does not emit

None. Every request, notification, structure, enumeration and type alias of
the 3.18.0 meta model is emitted (`lspgen: generation is deterministic`
checks each declaration exists).

Notes on mapping choices that are not one-to-one:

- `LSPAny`, `LSPObject` and `LSPArray` map to `std.json.Value`,
  `std.json.ArrayHashMap(std.json.Value)` and `[]const std.json.Value`
  instead of a recursive union.
- `--since-max` filters requests, notifications, properties and enum
  values; it does not remove whole structures, since other types may
  reference them.
- `--include-proposed` emits proposed entities at the top level. The 3.17
  and 3.18 models contain no proposed entities.
