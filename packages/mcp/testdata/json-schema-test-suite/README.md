# JSON-Schema-Test-Suite (vendored data)

Test data from <https://github.com/json-schema-org/JSON-Schema-Test-Suite>
at the commit in `UPSTREAM_COMMIT`, copied verbatim (MIT, see `LICENSE`).
Only what the zg_mcp runner (`src/schema/suite_test.zig`) uses is kept:

- `tests/draft2020-12/*.json`, `tests/draft7/*.json` (required);
- `tests/*/optional/format/{email,uri,date,date-time}.json` (the formats
  MCP elicitation asserts);
- `remotes/` for 2020-12 and draft-07, served as `http://localhost:1234/`.

`expected-failures.txt` lists documented exceptions, one
`<draft>/<file>: <group> / <test>` per line.
