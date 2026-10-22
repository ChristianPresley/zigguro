//! Tests for web_fetch.zig and web_search.zig (E10.F06.S03.T03) against
//! the fake transport.

const std = @import("std");
const proto = @import("zg_ai_proto");
const fake = @import("../../provider/fake_server.zig");
const scripted = @import("../../provider/scripted.zig");
const request = @import("../../provider/request.zig");
const deps = @import("../../loop/deps.zig");
const web_fetch = @import("web_fetch.zig");
const web_search = @import("web_search.zig");

const testing = std.testing;
const io = testing.io;

fn callSpec(spec: *const proto.ToolSpec, a: std.mem.Allocator, input: []const u8) !proto.ToolOutput {
    var c: proto.ToolCall = .{
        .id = "toolu_1",
        .name = spec.name,
        .input_json = input,
        .input = try std.json.parseFromSliceLeaky(std.json.Value, a, input, .{}),
        .arena = a,
        .io = io,
    };
    return spec.handler.call(spec.handler.ctx, &c);
}

const page_html = "<html><body><nav>menu</nav><main><h1>Title</h1><p>Hello <a href=\"/x\">x</a>.</p></main></body></html>";

const routes = [_]fake.Route{
    .{ .url_contains = "https://docs.example.com/page", .headers = &.{.{ .name = "content-type", .value = "text/html; charset=utf-8" }}, .body = page_html },
    .{ .url_contains = "https://docs.example.com/moved", .status = 301, .headers = &.{.{ .name = "location", .value = "/page" }} },
    .{ .url_contains = "https://docs.example.com/away", .status = 302, .headers = &.{.{ .name = "location", .value = "https://evil.example.net/steal" }} },
    .{ .url_contains = "https://docs.example.com/api.json", .headers = &.{.{ .name = "content-type", .value = "application/json" }}, .body = "{\"ok\":true}" },
    .{ .url_contains = "https://docs.example.com/logo.png", .headers = &.{.{ .name = "content-type", .value = "image/png" }}, .body = "\x89PNG...." },
    .{ .url_contains = "https://docs.example.com/paper.pdf", .headers = &.{.{ .name = "content-type", .value = "application/pdf" }}, .body = "%PDF-1.4 tiny" },
    .{ .url_contains = "https://docs.example.com/big", .headers = &.{.{ .name = "content-type", .value = "text/plain" }}, .body = "x" ** 300, .chunk_size = 64 },
    .{ .url_contains = "https://docs.example.com/missing", .status = 404, .body = "nope" },
};

const Fx = struct {
    ft: fake.FakeTransport,
    wf: web_fetch.WebFetch,
    arena: std.heap.ArenaAllocator,

    fn init(f: *Fx, cfg: web_fetch.Config) !void {
        f.ft = try .init(testing.allocator, &routes);
        f.wf = .init(testing.allocator, io, f.ft.transport(), cfg);
        f.arena = .init(testing.allocator);
    }

    fn deinit(f: *Fx) void {
        f.wf.deinit();
        f.ft.deinit();
        f.arena.deinit();
    }

    fn fetch(f: *Fx, input: []const u8) !proto.ToolOutput {
        return callSpec(&f.wf.specs()[0], f.arena.allocator(), input);
    }
};

test "fetch_fake_server" {
    var f: Fx = undefined;
    try f.init(.{ .max_body_bytes = 256 });
    defer f.deinit();
    const page = try f.fetch("{\"url\":\"https://docs.example.com/page\"}");
    try testing.expectEqualStrings("[untrusted web content from docs.example.com]\n# Title\n\nHello [x](https://docs.example.com/x).", page.parts[0].text);
    // http is upgraded; a same-host redirect is followed.
    const moved = try f.fetch("{\"url\":\"http://docs.example.com/moved\"}");
    try testing.expect(std.mem.indexOf(u8, moved.parts[0].text, "# Title") != null);
    // A cross-host redirect is reported, not followed.
    const away = try f.fetch("{\"url\":\"https://docs.example.com/away\"}");
    try testing.expectEqualStrings("Redirected to https://evil.example.net/steal; call web_fetch again with that URL if you want it.", away.parts[0].text);
    for (f.ft.requests()) |r| try testing.expect(std.mem.indexOf(u8, r.url, "evil") == null);
    // Content types.
    try testing.expectEqualStrings("[untrusted web content from docs.example.com]\n{\"ok\":true}", (try f.fetch("{\"url\":\"https://docs.example.com/api.json\"}")).parts[0].text);
    try testing.expect(std.mem.endsWith(u8, (try f.fetch("{\"url\":\"https://docs.example.com/logo.png\"}")).parts[0].text, "image/png content (8 bytes) is not text and is not shown."));
    try testing.expect(std.mem.indexOf(u8, (try f.fetch("{\"url\":\"https://docs.example.com/paper.pdf\"}")).parts[0].text, "cannot read PDFs") != null);
    // The size cap.
    const big = try f.fetch("{\"url\":\"https://docs.example.com/big\"}");
    try testing.expect(big.is_error);
    try testing.expectEqualStrings("https://docs.example.com/big is larger than 0 MiB; not fetched.", big.parts[0].text);
    const missing = try f.fetch("{\"url\":\"https://docs.example.com/missing\"}");
    try testing.expectEqualStrings("HTTP 404 fetching https://docs.example.com/missing.", missing.parts[0].text);
    // Other schemes are refused.
    try testing.expectEqualStrings("Only https URLs can be fetched.", (try f.fetch("{\"url\":\"file:///etc/passwd\"}")).parts[0].text);
    // max_chars cuts the page.
    const cut = try f.fetch("{\"url\":\"https://docs.example.com/page\",\"max_chars\":7}");
    try testing.expectEqualStrings("[untrusted web content from docs.example.com]\n# Title\n[truncated: showing 7 of 47 chars; pass a larger max_chars to see more]", cut.parts[0].text);
}

test "pages are cached" {
    var f: Fx = undefined;
    try f.init(.{});
    defer f.deinit();
    _ = try f.fetch("{\"url\":\"https://docs.example.com/page\"}");
    _ = try f.fetch("{\"url\":\"https://docs.example.com/page\"}");
    try testing.expectEqual(@as(usize, 1), f.ft.requests().len);
}

test "pdf as a document part" {
    var f: Fx = undefined;
    try f.init(.{ .pdf_input = true });
    defer f.deinit();
    const o = try f.fetch("{\"url\":\"https://docs.example.com/paper.pdf\"}");
    try testing.expectEqualStrings("application/pdf", o.parts[1].document.media_type);
}

const Deny = struct {
    fn check(_: *anyopaque, _: std.Io, _: proto.AgentRef, host: []const u8, _: []const u8) std.Io.Cancelable!deps.Decision {
        if (std.mem.endsWith(u8, host, "example.com")) return .{ .deny = "rule WebFetch(domain:*.example.com)" };
        return .allow;
    }
};

test "domain_policy_deny" {
    var f: Fx = undefined;
    try f.init(.{});
    defer f.deinit();
    var d: u8 = 0;
    f.wf.policy = .{ .ctx = &d, .check = Deny.check };
    const o = try f.fetch("{\"url\":\"https://docs.example.com/page\"}");
    try testing.expect(o.is_error);
    try testing.expectEqualStrings("Fetching docs.example.com is not allowed: rule WebFetch(domain:*.example.com)", o.parts[0].text);
    try testing.expectEqual(@as(usize, 0), f.ft.requests().len);
}

test "prompt_mode_uses_assist_model" {
    var f: Fx = undefined;
    try f.init(.{});
    defer f.deinit();
    const turns = [_][]const scripted.ScriptedProvider.Step{scripted.script.text("The title is Title.")};
    const sp = try scripted.ScriptedProvider.init(testing.allocator, &turns, .{});
    const p = sp.provider();
    defer p.deinit();
    var pa: web_fetch.ProviderAssist = .{ .provider = p, .model = "claude-haiku-5-5" };
    f.wf.assist = pa.assist();
    const o = try f.fetch("{\"url\":\"https://docs.example.com/page\",\"prompt\":\"What is the title?\"}");
    try testing.expectEqualStrings("[untrusted web content from docs.example.com]\nThe title is Title.\n\nSource: https://docs.example.com/page", o.parts[0].text);
    const req = sp.requests()[0];
    try testing.expectEqualStrings("claude-haiku-5-5", req.model);
    try testing.expectEqual(@as(usize, 0), req.system.len);
    try testing.expect(std.mem.indexOf(u8, req.messages[0].content[0].text.text, "# Title") != null);
}

test "url helpers" {
    try testing.expectEqualStrings("docs.example.com", web_fetch.hostOf("https://user@docs.example.com:8443/a?b").?);
    try testing.expectEqualStrings("[::1]", web_fetch.hostOf("https://[::1]:80/").?);
    try testing.expect(web_fetch.hostOf("https:///x") == null);
}

const search_routes = [_]fake.Route{
    .{ .url_contains = "https://search.example/api?q=zig%20allocators&n=3", .body =
    \\{"web":{"results":[
    \\ {"title":"Allocators","url":"https://ziglang.org/learn/allocators","description":"How allocators work."},
    \\ {"title":"Spam","url":"https://spam.example.com/x","description":"buy"},
    \\ {"title":"Blog","url":"https://blog.ziglang.org/post","description":" A post. "},
    \\ {"title":"Other","url":"https://other.dev/y"}
    \\]}}
    },
};

test "search_native_vs_http_vs_disabled_registration" {
    var ft: fake.FakeTransport = try .init(testing.allocator, &search_routes);
    defer ft.deinit();
    var off: web_search.WebSearch = .init(io, ft.transport(), .disabled);
    try testing.expectEqual(@as(usize, 0), off.specs().len);

    var native: web_search.WebSearch = .init(io, ft.transport(), .provider_native);
    const ns = &native.specs()[0];
    try testing.expectEqual(proto.ProviderId.anthropic, ns.native.?.provider);
    // Declared verbatim to Anthropic models only.
    const d = request.declFor(ns, .anthropic).?;
    try testing.expect(d.kind == .provider_native);
    try testing.expectEqualStrings(web_search.anthropic_native_json, d.raw_json.?);
    try testing.expect(request.declFor(ns, .openai_responses) == null);

    var http: web_search.WebSearch = .init(io, ft.transport(), .{ .http_json = .{
        .url_template = "https://search.example/api?q={query}&n={count}",
        .headers = &.{.{ .name = "x-api-key", .value = "k" }},
        .results_path = "web.results",
        .snippet_field = "description",
    } });
    const hs = &http.specs()[0];
    try testing.expect(hs.native == null);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const o = try callSpec(hs, arena.allocator(), "{\"query\":\"zig allocators\",\"max_results\":3,\"blocked_domains\":[\"example.com\"]}");
    try testing.expectEqualStrings(
        \\[untrusted web content from search results]
        \\Results for "zig allocators":
        \\1. Allocators
        \\   https://ziglang.org/learn/allocators
        \\   How allocators work.
        \\2. Blog
        \\   https://blog.ziglang.org/post
        \\   A post.
        \\3. Other
        \\   https://other.dev/y
        \\
    , o.parts[0].text);
    try testing.expectEqualStrings("k", ft.requests()[0].headers[0].value);
    const only = try callSpec(hs, arena.allocator(), "{\"query\":\"zig allocators\",\"max_results\":3,\"allowed_domains\":[\"ziglang.org\"]}");
    try testing.expect(std.mem.indexOf(u8, only.parts[0].text, "other.dev") == null);
    try testing.expect(std.mem.indexOf(u8, only.parts[0].text, "blog.ziglang.org") != null);
}
