//! Projects (E13.F09): named groups of runs, tasks, automations and
//! artifacts with instructions and a knowledge index that agents started in
//! the project see.

pub const project = @import("project.zig");
pub const knowledge = @import("knowledge.zig");
pub const ProjectStore = @import("store.zig");
pub const context = @import("context.zig");
pub const tools = @import("tools.zig");

pub const Project = project.Project;
pub const ProjectFile = project.ProjectFile;
pub const KnowledgeItem = project.KnowledgeItem;
pub const KnowledgeIndex = knowledge.KnowledgeIndex;
pub const ProjectsView = ProjectStore.ProjectsView;
pub const Context = context.Context;

test {
    _ = project;
    _ = knowledge;
    _ = ProjectStore;
    _ = context;
    _ = tools;
    _ = @import("project_test.zig");
    _ = @import("store_test.zig");
    _ = @import("context_test.zig");
}
