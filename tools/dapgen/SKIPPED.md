# Schema definitions dapgen does not emit

None. All 192 definitions of `debugAdapterProtocol.json` are emitted
(`dapgen: generation is deterministic and complete` checks each one).

Notes on mapping choices that are not one-to-one:

- The generic `arguments` / `body` of `Request`, `Response` and `Event`
  (any JSON type) are `std.json.Value`; a message that does not narrow them
  has `void` as its `Arguments` / `ResponseBody` / `EventBody`.
- Inline objects without properties (adapter-specific payloads such as
  `StartDebuggingRequestArguments.configuration`) are `std.json.Value`.
- Closed enums have an extra `_unknown` member: adapters routinely send
  values newer than the schema, and a debug session must not fail on them.
  An `_unknown` value is written back as the string `"_unknown"`.
