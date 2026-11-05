//! Design notes, fault model, and TigerStyle deviations: see docs/ARCHITECTURE.md.
pub const Body = @import("payload/Body.zig");
pub const BodyIter = @import("payload/operators.zig").BodyIter;
pub const Builder = @import("Builder.zig");
pub const Counts = @import("payload/Counts.zig");
pub const Cursor = @import("Cursor.zig");
pub const CustomEdit = @import("custom/edit.zig").Edit;
pub const CustomPlacement = @import("custom/edit.zig").Placement;
pub const CustomSelector = @import("custom/edit.zig").Selector;
pub const CustomSource = @import("custom/edit.zig").Source;
pub const Diagnostics = @import("Diagnostics.zig");
pub const Edit = @import("edit.zig").Edit;
pub const Module = @import("Module.zig");
pub const Options = @import("Options.zig");
pub const Patch = @import("Patch.zig");
pub const Plan = @import("Plan.zig");
pub const Query = @import("Query.zig");
pub const ValueType = @import("spec.zig").ValueType;
pub const custom = struct {
    pub const dylink = @import("custom/dylink.zig");
};
pub const index = @import("index.zig");
pub const emit = @import("emit.zig").emit;
pub const outputLen = @import("emit.zig").outputLen;

test {
    _ = @import("tests/all.zig");
}
