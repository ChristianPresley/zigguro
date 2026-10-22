# Security invariants

Owner: E16. Spec: E16.F01.S01.T01. Each invariant has a stable ID; tests that prove it carry the ID in their name (`test "INV-03 deny beats allow"`). An invariant may only be removed by an ADR.

**INV-01 Every tool call passes `Engine.decide`.** No consumer (E06 terminals, E07 tasks, E08 file operations, E09 SCM, E10 tools, E11 MCP) executes, writes or connects on behalf of an agent without a decision. The `test-enforcement` harness (E16.F02.S01.T04) runs every consumer against a deny-all engine and proves nothing happens. `contracts.zig` stays dependency-free so every consumer can afford to import it.

**INV-02 Unknown means ask.** A request no rule matches, a command the shell analyzer cannot parse, a tool without declared effects and an unknown MCP tool all resolve to `ask` (or `deny` in `dont_ask` mode). Failing closed is the only safe default when the engine's understanding is incomplete.

**INV-03 Deny beats allow across all layers.** A deny rule in any layer (managed, CLI, workspace, user, defaults) wins over every allow rule in every layer, and over session grants. Precedence between layers only matters for `ask` versus `allow`.

**INV-04 Bypass cannot be forced.** `bypass` mode cannot be entered when managed policy disables it, and it is never restored when a session resumes; a resumed session starts in `default` (or the managed default).

**INV-05 Protected paths always ask and are read-only in sandboxes.** Writes to `.git/`, `.zigguro/`, `.mcp.json`, `.vscode/`, `.cursor/`, shell profiles and the user config directory ask in every mode except `bypass`, and sandboxes bind them read-only so even an approved command cannot rewrite them.

**INV-06 Agent edits become changesets.** File edits by agents are E12 changesets the user reviews, unless policy (accept-edits mode or an explicit rule) auto-applies them; even then they are recorded.

**INV-07 Secrets never reach logs, transcripts, audit records or provider cassettes.** Every outbound text passes the redactor; the audit log stores secret names, never values.

**INV-08 Secret values never enter a sandboxed child's environment unless injected by name.** The environment scrubber removes credential-shaped variables; injection is explicit, per secret, and audited.

**INV-09 Untrusted workspaces never spawn workspace-configured executables.** Tasks, workspace-local LSP/DAP binaries, project MCP servers and git hooks from an untrusted folder do not run.

**INV-10 No outbound connection without an egress-policy decision.** Every socket the app opens (and every connection a sandboxed child makes through the proxy) is checked against the allowlist and the private-IP guard after DNS resolution, and the connection is pinned to the vetted address.

**INV-11 No telemetry socket by default.** With default settings and no provider configured, a headless run opens zero outbound sockets.

**INV-12 The audit chain verifies or reports the first broken record.** Each record hashes its predecessor; verification either succeeds or names the first sequence number whose hash does not match.

**INV-13 URIs open only via allowlisted schemes, never through a shell.** `http`, `https` and `mailto` (plus user-allowed schemes) open through the platform API with the URI as one argument; `file:`, `javascript:`, `data:` and unknown schemes ask or are denied.

**INV-14 Approvals are bound to the exact input hash they approved.** An approval (and a capability token) names the SHA-256 of the canonical input; a request with different input needs a new approval.

**INV-15 A changed MCP tool is not callable until re-approved.** Tool definitions (name, description, input schema, annotations) are pinned by hash when approved; any change holds the tool.

**INV-16 Annotations from untrusted MCP servers never relax a decision.** `readOnlyHint` and friends are honoured only when the server is trusted; from an untrusted server they can only make a decision stricter.
