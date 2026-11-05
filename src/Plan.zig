//! Plan-wide values every edit resolves against; built by `Plan.fromPatch`. Edits borrow it, so it
//! must outlive the encode call.
const AddTypes = @import("edit/AddTypes.zig");
const Patch = @import("Patch.zig");
const index = @import("index.zig");

/// How many imports of each kind the plan adds.
added_imports: index.AddedImports = .{},
/// Added signatures, in `.appended` ordinal order.
added_types: []const AddTypes.Signature = &.{},
/// Added function type indices, in `.appended` ordinal order.
added_functions: []const index.Type = &.{},

const Plan = @This();

/// Builds the plan from `patch`. A raw payload contributes nothing; its indices are the caller's.
pub fn fromPatch(patch: *const Patch) Plan {
    var plan: Plan = .{};
    if (patch.get(.import)) |edit| switch (edit.*) {
        .add_imports => |add_imports| plan.added_imports = add_imports.planAddedImports(),
        else => {},
    };
    if (patch.get(.type)) |edit| switch (edit.*) {
        .add_types => |add_types| plan.added_types = add_types.signatures,
        else => {},
    };
    if (patch.get(.function)) |edit| switch (edit.*) {
        .add_functions => |add_functions| plan.added_functions = add_functions.types,
        else => {},
    };
    return plan;
}
