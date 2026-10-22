# ZEP: the zigguro extension protocol

Status: draft, protocol version `2026-10`.

The key words MUST, MUST NOT, SHOULD, SHOULD NOT and MAY are to be
interpreted as described in RFC 2119.

ZEP is how a code-carrying extension talks to zigguro. The extension is a
separate process; the host starts it, speaks JSON-RPC 2.0 to it over stdio,
and can stop it at any time. Purely declarative extensions (themes,
keymaps, snippets, language definitions) never start a process and never
see ZEP.

ZEP never carries agent tools. An extension that wants to give agents tools
MUST also declare an MCP server (it MAY be the same executable started with
a different flag). ZEP is for editor integration: commands, views,
decorations, documents, settings and edits.

The message types live in `src/zep/protocol.zig`. The Zig SDK
(`src/zep/client.zig`, module `zg_ext_sdk`) implements the extension side.

## Transport

- The host starts the extension's `main` executable with stdin and stdout
  as pipes. stderr is captured into the extension's log.
- Messages are framed exactly as in the LSP base protocol: a
  `Content-Length: <n>\r\n` header, optional other headers, `\r\n`, then
  `n` bytes of UTF-8 JSON.
- A message MUST NOT exceed 16 MiB. A peer that receives a larger one
  discards it and replies `invalid_request` when it had an id.
- Both sides MAY send requests concurrently and MAY answer out of order.
- Ids are integers or strings, as in JSON-RPC 2.0.

## Lifecycle

1. The host sends `initialize` (request). The extension MUST NOT send any
   request before answering it.
2. The extension answers with its capabilities.
3. The host sends `initialized` (notification). The host MUST NOT send any
   other request before it.
4. The host sends `activate` (notification) with the activation event
   (`onCommand:hello.say`, `onLanguage:zig`, `onView:hello.tree`,
   `workspaceContains:build.zig`, `onStartupFinished`). It MAY send more
   `activate` notifications later.
5. To stop, the host sends `shutdown` (request, result `null`) and then
   `exit` (notification). The extension SHOULD exit within 2 s of `exit`;
   the host kills it after 5 s. Closing stdin also means exit.

A request the extension receives before `initialized` (other than
`initialize` and `shutdown`) MUST fail with `not_activated` (−32003).

### initialize

```ts
interface InitializeParams {
  protocolVersion: string;            // "2026-10"
  host: { name: string; version: string };
  extension: { id: string; root: string; storageDir: string; globalStorageDir: string };
  workspaceFolders: { uri: string; name: string }[];
  locale: string;                     // "en"
  positionEncoding: "utf-8" | "utf-16";
  capabilities: { views: boolean; decorations: boolean; quickPick: boolean;
                  statusItems: boolean; aiSample: boolean; positionEncodings: string[] };
  grantedPermissions: { fsRead: string[]; fsWrite: string[]; network: string[];
                        process: boolean; aiSample: boolean; secrets: string[] };
}
interface InitializeResult {
  protocolVersion: string;
  capabilities: { documentSync: boolean; decorations: boolean;
                  views: string[]; configurationSections: string[] };
}
```

The extension MUST reject a `protocolVersion` it does not support with
`invalid_request`. The host supports the current version and the previous
one, and sends the newest version the extension's manifest declares.

## Capabilities

The extension only receives what it asked for: `document/*` notifications
only with `documentSync`, `decorations/provide` only with `decorations`,
`view/*` only for the view ids it lists, `settings/didChange` only for its
`configurationSections`. Host methods the user did not grant a permission
for fail with `permission_denied` (−32001).

## Host to extension

| Method | Kind | Params | Result |
| --- | --- | --- | --- |
| `activate` | notification | `{ event }` | |
| `command/execute` | request | `{ id, args? }` | any JSON |
| `view/resolve` | request | `{ viewId }` | `{ root: ViewNode }` |
| `view/resolveChildren` | request | `{ viewId, nodeId }` | `ViewNode[]` |
| `view/event` | notification | `{ viewId, nodeId, kind: "click" \| "toggle" \| "input" \| "submit", value? }` | |
| `decorations/provide` | request | `{ uri, version, range? }` | `Decoration[]` |
| `settings/didChange` | notification | `{ sections: string[] }` | |
| `workspace/didChangeFolders` | notification | `{ added, removed }` | |
| `document/didOpen` | notification | `{ uri, languageId, version, text }` | |
| `document/didChange` | notification | `{ uri, version, changes: { range?, text }[] }` | |
| `document/didClose` | notification | `{ uri }` | |
| `shutdown` | request | | `null` |
| `exit` | notification | | |
| `$/cancelRequest` | notification | `{ id }` | |

`command/execute` is only sent for commands the manifest or
`commands/register` declared, and only after `activate`.

```ts
interface ViewNode { id: string; kind?: string; label: string; description?: string;
  icon?: string; command?: string; collapsible?: boolean; children?: ViewNode[] }
interface Decoration { range: Range; kind?: "highlight" | "underline" | "gutter" | "inline_text";
  color?: string; text?: string; hover?: string }
```

A view tree MUST NOT exceed 10 000 nodes; an extension MUST NOT return more
than 5 000 decorations per document.

## Extension to host

| Method | Kind | Params | Result |
| --- | --- | --- | --- |
| `commands/register` | notification | `{ commands: { id, title, category?, enablement? }[] }` | |
| `commands/execute` | request | `{ id, args? }` | any JSON |
| `window/showMessage` | request | `{ severity: "info" \| "warning" \| "error", message, actions? }` | chosen action or `null` |
| `window/showQuickPick` | request | `{ items: { label, description?, detail? }[], options: { placeholder?, canPickMany? } }` | indices or `null` |
| `window/showInput` | request | `{ prompt, value?, password? }` | string or `null` |
| `window/setStatusItem` | notification | `{ id, text, tooltip?, command?, priority? }` | |
| `view/update` | notification | `{ viewId, patch }` | |
| `decorations/refresh` | notification | `{ uri? }` | |
| `workspace/readFile` | request | `{ uri }` | `{ text? , base64? }` |
| `workspace/findFiles` | request | `{ glob, exclude?, max? }` | `string[]` |
| `workspace/applyEdit` | request | `{ label, edits: { uri, edits: TextEdit[] }[] }` | `{ changesetId?, applied }` |
| `settings/get` | request | `{ section, scopeUri? }` | any JSON |
| `storage/get`, `storage/set` | request | `{ key, value?, scope: "workspace" \| "global" }` | any JSON / `null` |
| `ai/sample` | request | `{ messages, systemPrompt?, maxTokens, modelHint? }` | `{ text, stopReason }` |
| `secrets/get` | request | `{ name }` | string or `null` |
| `log` | notification | `{ level, message }` | |
| `$/progress` | notification | `{ token, value }` | |

- Command ids an extension registers MUST start with `<extension name>.`.
- `workspace/applyEdit` goes through E13 changesets, so the user can review
  and undo an extension's edit as one step. `applied` is false when the user
  rejected it or a document changed underneath (`content_modified`).
- `ai/sample` follows MCP sampling semantics and needs the `aiSample`
  permission; the host MAY ask the user each time.
- `workspace/readFile` and `findFiles` are limited to `fsRead` globs;
  `applyEdit` to `fsWrite` globs.

## Positions

`Position` is `{ line, character }`, both zero-based. `character` counts in
the encoding negotiated by `positionEncoding`: UTF-8 bytes (preferred) or
UTF-16 code units (for authors porting LSP code), as in LSP 3.17. Ranges are
half-open.

## Errors and cancellation

Errors use the JSON-RPC error object. Codes:

| Code | Name | Meaning |
| --- | --- | --- |
| −32700 | `parse_error` | Malformed JSON. |
| −32600 | `invalid_request` | Not a valid request, or an unsupported protocol version. |
| −32601 | `method_not_found` | Unknown method or command. |
| −32602 | `invalid_params` | Params do not match. |
| −32603 | `internal` | The handler failed. |
| −32001 | `permission_denied` | The extension lacks the permission. |
| −32002 | `request_timeout` | The peer gave up waiting. |
| −32003 | `not_activated` | Too early in the lifecycle. |
| −32801 | `content_modified` | The document changed while the request ran. |
| −32800 | `request_cancelled` | Cancelled by `$/cancelRequest`. |

ZEP-specific codes use −32000..−32099. Either side MAY send
`$/cancelRequest { id }`; the receiver SHOULD stop and reply
`request_cancelled`, and MAY still reply with a result if it already
finished. The host cancels requests that take longer than 10 s
(`extensions.requestTimeoutMs`).

## Versioning

`protocolVersion` is a date string. Additive changes (new optional fields,
new methods guarded by a capability) keep the version. Anything else bumps
it, and the host keeps accepting the previous version for one release.
Peers MUST ignore unknown fields.

## The Zig SDK

```zig
const std = @import("std");
const zg_core = @import("zg_core");
const sdk = @import("zg_ext_sdk");

pub fn main(init: std.process.Init) !void {
    var rt: zg_core.Runtime = undefined;
    try rt.init(init.minimal, .{});
    const ext = try sdk.Extension.initStdio(&rt, .{});
    defer ext.deinit();
    try ext.onCommand("hello.say", say);
    try ext.run();
}

fn say(e: *sdk.Extension, args: ?std.json.Value, arena: std.mem.Allocator) anyerror!?std.json.Value {
    _ = args;
    _ = try e.showMessage(arena, .info, "Hello from Zig", &.{});
    return null;
}
```

The SDK answers `initialize`, `initialized`, `shutdown` and `exit`, refuses
unsupported protocol versions, and runs each `command/execute` handler on its
own unit of concurrency, so a handler may call blocking host methods.
`onRequest` registers handlers for the other host requests (`view/resolve`,
`decorations/provide`) the same way, and `onNotification` for the
notifications (`document/didOpen`, `settings/didChange`). Handler errors
become `internal` errors whose message names the command or method and the
Zig error.

## Examples

`packages/config/examples/zep/` holds three extensions, each with a
`zigguro-extension.zon` manifest:

- `hello_zig`: the SDK in use, with commands, a tree view and `TODO`
  decorations for open documents (`zig build examples` in `packages/config`).
- `hello_sh`: the framing in POSIX `sh` with `read`, `dd` and `printf`.
- `hello_ps1`: the same in PowerShell.
