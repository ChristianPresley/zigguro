//! zg_ai: the headless AI harness core (E10). Providers, the model
//! registry, cost accounting, the agent loop, context assembly, sessions
//! and the cassette/eval tooling. Never imports `zg_gui`.

const std = @import("std");

/// Canonical types (re-exported leaf module).
pub const proto = @import("zg_ai_proto");

pub const capabilities = @import("provider/capabilities.zig");
pub const events = @import("provider/events.zig");
pub const request = @import("provider/request.zig");
pub const assembler = @import("provider/assembler.zig");
pub const transport = @import("provider/transport.zig");
pub const translate = @import("provider/translate.zig");
pub const scripted = @import("provider/scripted.zig");
pub const fake_server = @import("provider/fake_server.zig");
pub const conformance = @import("provider/conformance.zig");
pub const sse_stream = @import("provider/sse_stream.zig");
/// The Anthropic Messages API provider (E10.F02).
pub const anthropic = struct {
    pub const Anthropic = @import("provider/anthropic/Anthropic.zig");
    pub const encode = @import("provider/anthropic/encode.zig");
    pub const decode = @import("provider/anthropic/decode.zig");
    pub const cache = @import("provider/anthropic/cache.zig");
    pub const recovery = @import("provider/anthropic/recovery.zig");
    test {
        _ = @import("provider/anthropic/anthropic_test.zig");
    }
};
/// OpenAI Responses and Chat Completions providers (E10.F03).
pub const openai = struct {
    pub const Responses = @import("provider/openai/Responses.zig");
    pub const Chat = @import("provider/openai/Chat.zig");
    pub const dialects = @import("provider/openai/dialects.zig");
    test {
        _ = @import("provider/openai/responses_test.zig");
        _ = @import("provider/openai/chat_test.zig");
    }
};
/// Gemini provider (E10.F03.S02.T02).
pub const gemini = struct {
    pub const Gemini = @import("provider/gemini/Gemini.zig");
    test {
        _ = @import("provider/gemini/gemini_test.zig");
    }
};
pub const wire = @import("provider/wire.zig");
pub const timefmt = @import("provider/timefmt.zig");
pub const retry = @import("provider/retry.zig");
pub const ratelimit = @import("provider/ratelimit.zig");
pub const guarded = @import("provider/guarded.zig");
pub const keyref = @import("provider/keyref.zig");
pub const hub = @import("provider/hub.zig");
/// Model registry, pricing, cost ledger and token estimator (E10.F04.S01).
pub const models = struct {
    pub const registry = @import("models/registry.zig");
    pub const pricing = @import("models/pricing.zig");
    pub const ledger = @import("models/ledger.zig");
    pub const estimate = @import("models/estimate.zig");
    test {
        _ = @import("models/registry_test.zig");
        _ = @import("models/ledger_test.zig");
        _ = @import("provider/ratelimit_test.zig");
        _ = @import("provider/hub_test.zig");
    }
};
/// The agent loop runtime (E10.F05).
pub const loop = struct {
    pub const events = @import("loop/events.zig");
    pub const bus = @import("loop/bus.zig");
    pub const scheduler = @import("loop/scheduler.zig");
    pub const budget = @import("loop/budget.zig");
    pub const deps = @import("loop/deps.zig");
    pub const input_queue = @import("loop/input_queue.zig");
    pub const Agent = @import("loop/Agent.zig");
    pub const AgentManager = @import("loop/Manager.zig");
    test {
        _ = @import("loop/bus_test.zig");
        _ = @import("loop/scheduler_test.zig");
        _ = @import("loop/turn_test.zig");
    }
};
/// Context engineering: memory files, rules, prompt assembly and
/// compaction (E10.F07).
pub const context = struct {
    pub const frontmatter = @import("context/frontmatter.zig");
    pub const rules = @import("context/rules.zig");
    pub const imports = @import("context/imports.zig");
    pub const memory = @import("context/memory.zig");
    pub const auto_memory = @import("context/auto_memory.zig");
    pub const reminders = @import("context/reminders.zig");
    pub const pins = @import("context/pins.zig");
    pub const cache_plan = @import("context/cache_plan.zig");
    pub const env_block = @import("context/env_block.zig");
    pub const assembler = @import("context/assembler.zig");
    pub const compactor = @import("context/compactor.zig");
    test {
        _ = @import("context/frontmatter_test.zig");
        _ = @import("context/memory_test.zig");
        _ = @import("context/auto_memory_test.zig");
        _ = @import("context/assembler_test.zig");
        _ = @import("context/compactor_test.zig");
    }
};
/// Sessions: the JSONL log, index, resume, fork and rewind (E10.F08).
/// `zg agent`: print mode, the REPL, `zg.stream/1` and exit codes (E10.F10.S01).
pub const headless = struct {
    pub const args = @import("headless/args.zig");
    pub const exit_codes = @import("headless/exit_codes.zig");
    pub const permission = @import("headless/permission.zig");
    pub const signals = @import("headless/signals.zig");
    pub const stream_json = @import("headless/stream_json.zig");
    pub const runner = @import("headless/runner.zig");
    pub const print = @import("headless/print.zig");
    pub const repl = @import("headless/repl.zig");
    pub const HeadlessOptions = args.HeadlessOptions;
    pub const ExitCode = exit_codes.ExitCode;
    pub const parseArgs = args.parseArgs;
    pub const runPrint = print.runPrint;
    pub const runRepl = repl.runRepl;
    test {
        _ = @import("headless/args_test.zig");
        _ = @import("headless/print_test.zig");
        _ = @import("headless/stream_json_test.zig");
    }
};
/// The tool system: registry, toolsets and built-in tools (E10.F06).
pub const tools = struct {
    pub const registry = @import("tools/registry.zig");
    pub const toolset = @import("tools/toolset.zig");
    pub const search_tools = @import("tools/search_tools.zig");
    pub const read_tracker = @import("tools/read_tracker.zig");
    pub const invoke = @import("tools/invoke.zig");
    /// Tools exported by other subsystems (LSP, workspace, SCM, MCP, ...).
    pub const adapters = struct {
        pub const foreign = @import("tools/adapters/foreign.zig");
        pub const all = @import("tools/adapters/all.zig");
    };
    /// Built-in tools.
    pub const builtin = struct {
        pub const terminal_host = @import("tools/builtin/terminal_host.zig");
        pub const fake_host = @import("tools/builtin/fake_host.zig");
        pub const run = @import("tools/builtin/run.zig");
        pub const process_host = @import("tools/builtin/process_host.zig");
        pub const files = @import("tools/builtin/files.zig");
        pub const read = @import("tools/builtin/read.zig");
        pub const edit = @import("tools/builtin/edit.zig");
        pub const write = @import("tools/builtin/write.zig");
        pub const disk_files = @import("tools/builtin/disk_files.zig");
        pub const fake_files = @import("tools/builtin/fake_files.zig");
        pub const html2md = @import("tools/builtin/html2md.zig");
        pub const web_fetch = @import("tools/builtin/web_fetch.zig");
        pub const web_search = @import("tools/builtin/web_search.zig");
    };
    pub const ToolRegistry = registry.ToolRegistry;
    pub const ToolSource = registry.ToolSource;
    pub const AgentTools = toolset.AgentTools;
    pub const ToolsetConfig = toolset.ToolsetConfig;
    test {
        _ = @import("tools/registry_test.zig");
        _ = @import("tools/invoke_test.zig");
        _ = @import("tools/adapters/adapters_test.zig");
        _ = @import("tools/builtin/run_test.zig");
        _ = @import("tools/builtin/process_host_test.zig");
        _ = @import("tools/builtin/read_test.zig");
        _ = @import("tools/builtin/edit_test.zig");
        _ = @import("tools/builtin/html2md_test.zig");
        _ = @import("tools/builtin/web_test.zig");
    }
};
/// Cassettes and the eval runner (E10.F10.S02).
pub const testing = struct {
    pub const cassette = @import("testing/cassette.zig");
    test {
        _ = @import("testing/cassette_test.zig");
    }
};
pub const session = struct {
    pub const key = @import("session/key.zig");
    pub const records = @import("session/records.zig");
    pub const writer = @import("session/writer.zig");
    pub const loader = @import("session/loader.zig");
    pub const store = @import("session/store.zig");
    pub const index = @import("session/index.zig");
    pub const search = @import("session/search.zig");
    pub const retention = @import("session/retention.zig");
    pub const title = @import("session/title.zig");
    pub const @"export" = @import("session/export.zig");
    pub const fork = @import("session/fork.zig");
    pub const @"resume" = @import("session/resume.zig");
    pub const rewind = @import("session/rewind.zig");
    test {
        _ = @import("session/store_test.zig");
        _ = @import("session/index_test.zig");
        _ = @import("session/resume_test.zig");
        _ = @import("session/fork_test.zig");
        _ = @import("session/rewind_test.zig");
    }
};
pub const schema = struct {
    pub const validate = @import("schema/validate.zig");
    pub const strict = @import("schema/strict.zig");
    pub const errors = @import("schema/errors.zig");
};

/// See `provider/Provider.zig`.
pub const Provider = @import("provider/Provider.zig");
/// See `capabilities.Capabilities`.
pub const Capabilities = capabilities.Capabilities;
/// See `request.Request`.
pub const Request = request.Request;
/// See `request.Response`.
pub const Response = request.Response;
/// See `events.StreamEvent`.
pub const StreamEvent = events.StreamEvent;
/// See `events.EventSink`.
pub const EventSink = events.EventSink;
/// See `assembler.MessageAssembler`.
pub const MessageAssembler = assembler.MessageAssembler;
/// See `transport.Transport`.
pub const Transport = transport.Transport;
/// See `hub.ProviderHub`.
pub const ProviderHub = hub.ProviderHub;
/// See `models.registry.ModelRegistry`.
pub const ModelRegistry = models.registry.ModelRegistry;
/// See `models.ledger.CostLedger`.
pub const CostLedger = models.ledger.CostLedger;
/// See `scripted.ScriptedProvider`.
pub const ScriptedProvider = scripted.ScriptedProvider;

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(schema);
    std.testing.refAllDecls(anthropic);
    std.testing.refAllDecls(openai);
    std.testing.refAllDecls(gemini);
    std.testing.refAllDecls(models);
    std.testing.refAllDecls(loop);
    std.testing.refAllDecls(context);
    std.testing.refAllDecls(session);
    std.testing.refAllDecls(testing);
    std.testing.refAllDecls(headless);
    std.testing.refAllDecls(tools);
    std.testing.refAllDecls(tools.builtin);
}
