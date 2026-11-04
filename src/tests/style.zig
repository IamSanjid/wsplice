//! TigerStyle: hard limit every line to at most 100 columns. `zig fmt` handles indentation and
//! wrapping only when it is asked to, but it has no column limit, so this test enforces one.
//!
//! The sources are embedded at compile time rather than read from disk, so the check needs no
//! filesystem, no allocator, and no particular target: it runs wherever the tests run.
//!
//! Scope: the production files of `src/wsplice`. `tests/` is still being cleaned up and is
//! deliberately exempt; remove that exemption when the test pass happens.
const std = @import("std");

const cols_max = 100;

const Source = struct {
    name: []const u8,
    text: []const u8,
};

/// Every production file under `src/wsplice`. A new file that is missing here is a file where the
/// rule is silently unenforced, so add it in the same commit that creates it.
const sources = [_]Source{
    .{ .name = "Builder.zig", .text = @embedFile("../Builder.zig") },
    .{ .name = "Cursor.zig", .text = @embedFile("../Cursor.zig") },
    .{ .name = "Diagnostics.zig", .text = @embedFile("../Diagnostics.zig") },
    .{ .name = "index.zig", .text = @embedFile("../index.zig") },
    .{ .name = "Module.zig", .text = @embedFile("../Module.zig") },
    .{ .name = "Options.zig", .text = @embedFile("../Options.zig") },
    .{ .name = "Patch.zig", .text = @embedFile("../Patch.zig") },
    .{ .name = "Plan.zig", .text = @embedFile("../Plan.zig") },
    .{ .name = "Query.zig", .text = @embedFile("../Query.zig") },
    .{ .name = "Run.zig", .text = @embedFile("../Run.zig") },
    .{ .name = "edit.zig", .text = @embedFile("../edit.zig") },
    .{ .name = "emit.zig", .text = @embedFile("../emit.zig") },
    .{ .name = "errors.zig", .text = @embedFile("../errors.zig") },
    .{ .name = "section.zig", .text = @embedFile("../section.zig") },
    .{ .name = "spec.zig", .text = @embedFile("../spec.zig") },
    .{ .name = "wsplice.zig", .text = @embedFile("../wsplice.zig") },
    .{ .name = "edit/AddExports.zig", .text = @embedFile("../edit/AddExports.zig") },
    .{ .name = "edit/AddFunctions.zig", .text = @embedFile("../edit/AddFunctions.zig") },
    .{ .name = "edit/AddGlobals.zig", .text = @embedFile("../edit/AddGlobals.zig") },
    .{ .name = "edit/AddImports.zig", .text = @embedFile("../edit/AddImports.zig") },
    .{ .name = "edit/AddTypes.zig", .text = @embedFile("../edit/AddTypes.zig") },
    .{ .name = "edit/Raw.zig", .text = @embedFile("../edit/Raw.zig") },
    .{ .name = "edit/SetBodies.zig", .text = @embedFile("../edit/SetBodies.zig") },
    .{ .name = "edit/SetTables.zig", .text = @embedFile("../edit/SetTables.zig") },
    .{ .name = "payload/Body.zig", .text = @embedFile("../payload/Body.zig") },
    .{ .name = "payload/Counts.zig", .text = @embedFile("../payload/Counts.zig") },
    .{ .name = "payload/code.zig", .text = @embedFile("../payload/code.zig") },
    .{ .name = "payload/const_expr.zig", .text = @embedFile("../payload/const_expr.zig") },
    .{ .name = "payload/exports.zig", .text = @embedFile("../payload/exports.zig") },
    .{ .name = "payload/functions.zig", .text = @embedFile("../payload/functions.zig") },
    .{ .name = "payload/globals.zig", .text = @embedFile("../payload/globals.zig") },
    .{ .name = "payload/imports.zig", .text = @embedFile("../payload/imports.zig") },
    .{ .name = "payload/limits.zig", .text = @embedFile("../payload/limits.zig") },
    .{ .name = "payload/operators.zig", .text = @embedFile("../payload/operators.zig") },
    .{ .name = "payload/tables.zig", .text = @embedFile("../payload/tables.zig") },
    .{ .name = "payload/types.zig", .text = @embedFile("../payload/types.zig") },
    .{ .name = "payload/valtype.zig", .text = @embedFile("../payload/valtype.zig") },
};

test "style: no production line is longer than 100 columns" {
    for (sources) |source| {
        var line_number: u32 = 0;
        var lines = std.mem.splitScalar(u8, source.text, '\n');
        while (lines.next()) |line| {
            line_number += 1;
            if (line.len <= cols_max) continue;
            // The failure message is the whole report: name, line, width, and the line itself.
            std.debug.print(
                "\n{s}:{d}: {d} columns (max {d}):\n{s}\n",
                .{ source.name, line_number, line.len, cols_max, line },
            );
            return error.LineTooLong;
        }
    }
}
