//! The era-adaptive MCP client (E11.F03): connection and era detection,
//! the typed request pipeline and its per-request metadata, and the
//! catalogs of what a server offers, exported to the agent as tools, and
//! the InputBroker that answers servers' requests for user input, with
//! headless models for elicitation forms, URL consent, sampling and roots.

pub const Client = @import("Client.zig");
pub const era = @import("era.zig");
pub const meta = @import("meta.zig");
pub const request = @import("request.zig");
pub const catalog = @import("catalog.zig");
pub const tool_hygiene = @import("tool_hygiene.zig");
pub const snapshot = @import("snapshot.zig");
pub const agent_tools = @import("agent_tools.zig");
pub const input = @import("input.zig");
pub const mrtr = @import("mrtr.zig");
pub const legacy_server_requests = @import("legacy_server_requests.zig");
pub const elicitation = @import("elicitation.zig");
pub const sampling = @import("sampling.zig");
pub const roots = @import("roots.zig");

pub const EraDetection = era.EraDetection;
pub const CallOptions = request.CallOptions;
pub const CancelToken = request.CancelToken;
pub const RequestError = request.RequestError;
pub const ErrorInfo = request.ErrorInfo;
pub const CatalogStore = catalog.CatalogStore;
pub const CatalogKind = catalog.CatalogKind;
pub const Catalog = catalog.Catalog;
pub const ToolCatalog = catalog.ToolCatalog;
pub const ToolEntry = catalog.ToolEntry;
pub const InputBroker = input.InputBroker;
pub const ServerInput = input.ServerInput;
pub const runWithInput = mrtr.runWithInput;
pub const FormModel = elicitation.FormModel;
pub const UrlConsent = elicitation.UrlConsent;
pub const SamplingModel = sampling.SamplingModel;
pub const SamplingExecutor = sampling.SamplingExecutor;
pub const RootsProvider = roots.RootsProvider;

test {
    _ = Client;
    _ = era;
    _ = meta;
    _ = request;
    _ = catalog;
    _ = tool_hygiene;
    _ = snapshot;
    _ = input;
    _ = mrtr;
    _ = legacy_server_requests;
    _ = elicitation;
    _ = sampling;
    _ = roots;
    _ = @import("mrtr_test.zig");
    _ = @import("catalog_test.zig");
    _ = @import("agent_tools_test.zig");
    _ = @import("client_test.zig");
    _ = @import("client_http_test.zig");
}
