//! Macro scenarios, environment capture and runner calibration
//! (E14.F06.S01.T02). The app's runner (`zigguro --bench-scenario=<name>`)
//! drives the scenarios; docs/perf/benchmarks.md describes them.

/// `Scenario` and `runScenario`.
pub const scenario = @import("scenario/scenario.zig");
/// `Context` and `Measurement`.
pub const context = @import("scenario/context.zig");
/// `Env`, `captureEnv`, `warnings` and `stabilize`.
pub const env = @import("scenario/env.zig");
/// `calibrate`: the machine scale factor.
pub const calibrate = @import("scenario/calibrate.zig");

pub const Scenario = scenario.Scenario;
pub const runScenario = scenario.runScenario;
pub const Context = context.Context;
pub const Measurement = context.Measurement;
pub const Env = env.Env;
pub const captureEnv = env.captureEnv;
pub const stabilize = env.stabilize;
pub const Calibration = calibrate.Calibration;
