//! The plan-wide values every edit resolves against, built from the patch by `Plan.fromPatch`.
//! `emit` and callers resolving indices use the same value; edits borrow it, so it must outlive
//! the encode call.
const AddTypes = @import("edit/AddTypes.zig");
const Patch = @import("Patch.zig");
const index = @import("index.zig");

/// How many imports of each kind the plan adds; every edit shifts indices by these.
added_imports: index.AddedImports = .{},
/// The signatures of the types the plan adds, in `.appended` ordinal order.
added_types: []const AddTypes.Signature = &.{},
/// The type of each function the plan adds, in `.appended` ordinal order.
added_functions: []const index.Type = &.{},

const Plan = @This();

/// The plan-wide values every edit resolves against. An edit the patch describes with a raw payload
/// is opaque: it contributes no values here and the caller owns its indices.
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
