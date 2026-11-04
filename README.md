# wsplice

Usage:
```sh
zig fetch --save git+https://github.com/zigtools/zls.git
```

```zig
const wsplice_dep = b.dependency("wsplice", .{
    .optimize = optimize,
});
const wsplice = wsplice_dep.module("wsplice");
//  exe/lib.root_module
//  .imports = &.{
//      .{ .name = "wsplice", .module = wsplice },
//  },
```

Example:

```zig
const std = @import("std");
const wsplice = @import("wsplice");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) {
        std.debug.print("Usage: {s} <wasm_file>\n", .{args[0]});
        return;
    }

    const wasm_file_path = args[1];
    const wasm_file = try std.Io.Dir.cwd().readFileAlloc(io, wasm_file_path, gpa, .unlimited);
    defer gpa.free(wasm_file);

    var diags: wsplice.Diagnostics = .{};
    const options = wsplice.Options{ .diag = &diags };
    errdefer std.debug.print("Diagnostics:\n{f}\n", .{diags});

    const module = try wsplice.Module.parseWith(wasm_file, options);
    const query = try module.query(options);

    const func = (try query.functionInfo(0)) orelse {
        std.debug.print("Function 0 not found\n", .{});
        return;
    };

    const func_body = func.body.?;
    const func_type = func.type_ref.?;
    const func_signature = func.signature.?;

    std.debug.print(
        "Function 0: type={any}, params_count={d}, body_size={d}\n",
        .{ func_type, try func_signature.paramCount(), func_body.bodyRaw().len },
    );

    const table = (try query.tableInfo(0)) orelse {
        std.debug.print("Table 0 not found\n", .{});
        return;
    };
    if (table.origin != .defined) {
        std.debug.print("Table 0 is not defined\n", .{});
        return;
    }
    var table_type = table.table_type.?;
    if (table_type.reftype != .func) {
        std.debug.print("Table 0 is not a function table\n", .{});
        return;
    }
    if (table_type.limits.flags.has_max) {
        table_type.limits.max += 2;
    }

    var builder: wsplice.Builder = .{};
    defer builder.deinit(gpa);

    try builder.setTable(gpa, .{ .input = 0 }, table_type);

    const new_global = try builder.addGlobal(gpa, .{
        .global_type = .{
            .mutability = .mutable,
            .valtype = .{
                .number_or_vector = .i32,
            },
        },
        .init = .{
            .i32 = 0,
        },
    });
    try builder.addExport(gpa, "hook_indirect", .{ .global = new_global });

    const new_func = try builder.addFunction(gpa, func_type);
    try builder.setBody(gpa, new_func, func_body.body());

    // const new_type = try builder.addType(gpa, .{ .params = func_signature.params });

    const Transform = struct {
        g: wsplice.index.Global,
        copied: wsplice.index.Function,
        func_type_index: wsplice.index.Type,
        params_count: u32,

        pub fn rewrite(self: *const @This(), _: wsplice.BodyIter, out: *wsplice.Body.Out) !void {
            // Arguments for the indirect call: the original parameters, then the table slot.
            for (0..self.params_count) |i| {
                try out.write(&.{
                    .{ .local_get = @truncate(i) },
                });
            }
            try out.write(&.{
                .{ .global_get = self.g },
            });
            try out.write(&.{
                .{
                    .call_indirect = .{
                        .type = self.func_type_index,
                        .table = .{ .input = 0 },
                    },
                },
            });

            // for (0..self.params_count) |i| {
            //     try out.write(&.{
            //         .{ .local_get = @truncate(i) },
            //     });
            // }
            // try out.write(&.{
            //     .{ .call = self.copied },
            // });
        }
    };
    var transform: Transform = .{
        .func_type_index = func_type,
        .params_count = try func_signature.paramCount(),
        .g = new_global,
        .copied = new_func,
    };

    try builder.setBody(gpa, .{ .input = 0 }, .{
        .locals = .keep,
        .mode = .{ .rewrite = .from(&transform) },
    });

    const out_file = try std.Io.Dir.cwd().createFile(io, "out.wasm", .{});
    var buf: [256]u8 = undefined;
    var f_writer = out_file.writer(io, &buf);

    const patch = try builder.patch();
    try wsplice.emit(&module, &patch, &f_writer.interface, options);

    try f_writer.flush();
}
