//! Design notes, fault model, and TigerStyle deviations: see docs/ARCHITECTURE.md.
pub const Body = @import("payload/Body.zig");
pub const BodyIter = @import("payload/operators.zig").BodyIter;
pub const Builder = @import("Builder.zig");
pub const Cursor = @import("Cursor.zig");
pub const Counts = @import("payload/Counts.zig");
pub const Diagnostics = @import("Diagnostics.zig");
pub const Edit = @import("edit.zig").Edit;
pub const Module = @import("Module.zig");
pub const Options = @import("Options.zig");
pub const Patch = @import("Patch.zig");
pub const Plan = @import("Plan.zig");
pub const Query = @import("Query.zig");
pub const index = @import("index.zig");
pub const ValueType = @import("spec.zig").ValueType;
pub const emit = @import("emit.zig").emit;
pub const outputLen = @import("emit.zig").outputLen;

test {
    _ = Body;
    _ = Builder;
    _ = Module;
    _ = Patch;
    _ = Diagnostics;
    _ = Edit;
    _ = Options;
    _ = Query;
    _ = emit;
    _ = outputLen;
    _ = @import("spec.zig");
    _ = @import("index.zig");
    _ = @import("section.zig");
    _ = @import("edit.zig");
    _ = @import("edit/Raw.zig");
    _ = @import("edit/AddExports.zig");
    _ = @import("edit/AddFunctions.zig");
    _ = @import("edit/AddTypes.zig");
    _ = @import("emit.zig");
    _ = @import("payload/const_expr.zig");
    _ = @import("payload/exports.zig");
    _ = @import("payload/functions.zig");
    _ = @import("payload/limits.zig");
    _ = @import("payload/operators.zig");
    _ = @import("payload/types.zig");
    _ = @import("payload/valtype.zig");

    _ = @import("tests/all.zig");
}
