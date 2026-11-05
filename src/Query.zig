//! Reads a module without allocating: bodies, types, signatures, table types, custom sections, and
//! origins. Query values borrow the module.
const std = @import("std");
const assert = std.debug.assert;

const Cursor = @import("Cursor.zig");
const Module = @import("Module.zig");
const Options = @import("Options.zig");
const Counts = @import("payload/Counts.zig");
const Body = @import("payload/Body.zig");
const code = @import("payload/code.zig");
const custom = @import("payload/custom.zig");
const functions = @import("payload/functions.zig");
const imports = @import("payload/imports.zig");
const tables = @import("payload/tables.zig");
const types = @import("payload/types.zig");
const operators = @import("payload/operators.zig");
const index = @import("index.zig");
const errors = @import("errors.zig");
const PayloadError = errors.PayloadError;
const spec = @import("spec.zig");

module: *const Module,
counts: Counts,

const Query = @This();

pub fn init(module: *const Module, options: Options) PayloadError!Query {
    return initWithCounts(module, try Counts.of(module, options));
}

/// `init` when the caller already has the module's counts, so they are not scanned twice.
pub fn initWithCounts(module: *const Module, counts: Counts) Query {
    return .{ .module = module, .counts = counts };
}

/// The body of function `function`, or null when it is imported, absent, or has no code entry.
pub fn functionBody(self: *const Query, function: u32) PayloadError!?FunctionBody {
    if (function >= self.counts.total(.function)) return null;
    const imported = self.counts.importedCount(.function);
    if (function < imported) return null;
    const ordinal = function - imported;

    const payload = self.module.payloadCursor(.code) orelse return null;
    var iterator = try code.Iterator.init(payload);
    if (ordinal >= iterator.count) return null;

    var skipped: u32 = 0;
    while (skipped < ordinal) : (skipped += 1) _ = try iterator.next();
    const entry = (try iterator.next()) orelse return null;
    return try FunctionBody.init(&entry);
}

/// The type of function `function`, imported or defined, or null when no function has that index.
pub fn functionType(self: *const Query, function: u32) PayloadError!?index.Type {
    if (function >= self.counts.total(.function)) return null;
    const imported = self.counts.importedCount(.function);
    if (function < imported) return importedType(self, function);
    return definedType(self, function - imported);
}

/// The parameters and results of a function, imported or defined; null when absent or when its
/// type index is not in the type section.
pub fn functionSignature(self: *const Query, function: u32) PayloadError!?types.Signature {
    const function_type = (try self.functionType(function)) orelse return null;
    const type_index = switch (function_type) {
        .input => |input| input,
        // An input function's type is always an input type.
        .appended, .added_import => return null,
    };
    return self.typeSignature(type_index);
}

/// The type of table `table`, imported or defined, or null when no table has that index.
pub fn tableType(self: *const Query, table: u32) PayloadError!?tables.Type {
    if (table >= self.counts.total(.table)) return null;
    const imported = self.counts.importedCount(.table);
    if (table < imported) return importedTableType(self, table);
    return definedTableType(self, table - imported);
}

/// Where an entity in an index space comes from.
pub const Origin = enum { imported, defined };

/// Everything a plan usually asks about one function. `body` is null for an imported function or a
/// defined function with no code entry; `type_ref`/`signature` are null for an inconsistent input.
pub const FunctionInfo = struct {
    origin: Origin,
    type_ref: ?index.Type,
    signature: ?types.Signature,
    body: ?FunctionBody,
};

/// A table's type and origin. `table_type` is null only when the relevant section is malformed.
pub const TableInfo = struct {
    origin: Origin,
    table_type: ?tables.Type,
};

/// The function's origin and, when available, its type, signature and body. Prefer this to several
/// targeted calls when a plan needs more than one fact.
pub fn functionInfo(self: *const Query, function: u32) PayloadError!?FunctionInfo {
    if (function >= self.counts.total(.function)) return null;
    const origin: Origin = if (function < self.counts.importedCount(.function))
        .imported
    else
        .defined;

    const type_ref = try self.functionType(function);
    const signature = if (type_ref) |ref| switch (ref) {
        .input => |type_index| try self.typeSignature(type_index),
        .appended, .added_import => null,
    } else null;
    const body = if (origin == .defined) try self.functionBody(function) else null;

    return .{
        .origin = origin,
        .type_ref = type_ref,
        .signature = signature,
        .body = body,
    };
}

/// A custom section as the input has it. `name` and `data` are borrowed raw bytes; `data` follows
/// the name vector, and `section` is the frame.
pub const CustomSection = struct {
    name: []const u8,
    data: []const u8,
    section: Module.Section,
};

/// Iterates custom sections in file order. Non-custom sections are skipped.
pub const CustomSectionIter = struct {
    module: *const Module,
    sections: Module.SectionIter,

    pub fn next(self: *CustomSectionIter) PayloadError!?CustomSection {
        while (true) {
            // The module was parsed, so its section framing cannot fail here.
            const section = (self.sections.next() catch unreachable) orelse return null;
            if (section.id != .custom) continue;
            const entry = try custom.read(self.module.bytes, section.payload);
            return .{ .name = entry.name, .data = entry.data, .section = section };
        }
    }
};

/// Custom sections in file order. Custom sections can repeat, so this is an iterator, not an index.
pub fn customSections(self: *const Query) CustomSectionIter {
    return .{ .module = self.module, .sections = self.module.iterator() };
}

/// The first custom section with exactly `name`, in file order; null when there is none. Use
/// `customSections` when all occurrences matter.
pub fn customSection(self: *const Query, name: []const u8) PayloadError!?CustomSection {
    var iterator = self.customSections();
    while (try iterator.next()) |section| {
        if (std.mem.eql(u8, section.name, name)) return section;
    }
    return null;
}

/// The table's origin and type, or null when no table has that index.
pub fn tableInfo(self: *const Query, table: u32) PayloadError!?TableInfo {
    if (table >= self.counts.total(.table)) return null;
    const origin: Origin = if (table < self.counts.importedCount(.table))
        .imported
    else
        .defined;
    return .{
        .origin = origin,
        .table_type = try self.tableType(table),
    };
}

/// The function type at `type_index` in the input, or null when the input has no such entry.
pub fn typeSignature(self: *const Query, type_index: u32) PayloadError!?types.Signature {
    if (type_index >= self.counts.typeCount()) return null;
    const payload = self.module.payloadCursor(.type) orelse return null;
    var iterator = try types.Iterator.init(payload);
    if (type_index >= iterator.count) return null;

    var skipped: u32 = 0;
    while (skipped < type_index) : (skipped += 1) _ = try iterator.next();
    const entry = (try iterator.next()) orelse return null;
    return types.Signature.fromEntry(entry);
}

fn importedType(self: *const Query, ordinal: u32) PayloadError!?index.Type {
    const payload = self.module.payloadCursor(.import) orelse return null;
    var iterator = try imports.Iterator.init(payload);
    var seen: u32 = 0;
    while (try iterator.next()) |entry| {
        switch (entry.desc) {
            .function => |type_index| {
                if (seen == ordinal) return .{ .input = type_index };
                seen += 1;
            },
            else => {},
        }
    }
    return null;
}

fn definedType(self: *const Query, ordinal: u32) PayloadError!?index.Type {
    const payload = self.module.payloadCursor(.function) orelse return null;
    var iterator = try functions.Iterator.init(payload);
    var skipped: u32 = 0;
    while (skipped < ordinal) : (skipped += 1) {
        if (try iterator.next() == null) return null;
    }
    const type_index = (try iterator.next()) orelse return null;
    return .{ .input = type_index };
}

fn importedTableType(self: *const Query, ordinal: u32) PayloadError!?tables.Type {
    const payload = self.module.payloadCursor(.import) orelse return null;
    var iterator = try imports.Iterator.init(payload);
    var seen: u32 = 0;
    while (try iterator.next()) |entry| {
        switch (entry.desc) {
            .table => |table_type| {
                if (seen == ordinal) return table_type;
                seen += 1;
            },
            else => {},
        }
    }
    return null;
}

fn definedTableType(self: *const Query, ordinal: u32) PayloadError!?tables.Type {
    const payload = self.module.payloadCursor(.table) orelse return null;
    var iterator = try tables.Iterator.init(payload);
    if (ordinal >= iterator.count) return null;
    var skipped: u32 = 0;
    while (skipped < ordinal) : (skipped += 1) _ = try iterator.next();
    const entry = (try iterator.next()) orelse return null;
    return entry.table_type;
}

/// One function's body as the input has it: the locals vector and the expression, both borrowed.
pub const FunctionBody = struct {
    /// The locals vector as encoded: the run count, then each run's count and type.
    locals: []const u8,
    /// The instructions plus the terminating `end`.
    expression: Cursor,

    fn init(entry: *const code.Entry) PayloadError!FunctionBody {
        const expression = entry.body;
        if (expression.end == expression.pos) return error.Truncated;
        if (expression.bytes[expression.end - 1] != @backingInt(spec.BaseOpcode.end))
            return error.Truncated;
        return .{ .locals = entry.locals, .expression = expression };
    }

    /// A fresh reader over the instructions; the terminating `end` is not yielded.
    pub fn instructions(self: *const FunctionBody) operators.BodyIter {
        return operators.BodyIter.init(self.expression);
    }

    /// The instruction bytes, without the terminating `end`.
    pub fn bodyRaw(self: *const FunctionBody) []const u8 {
        assert(self.expression.pos < self.expression.end);
        return self.expression.bytes[self.expression.pos .. self.expression.end - 1];
    }

    /// A body that copies this one: the raw locals vector and the raw instructions.
    pub fn body(self: *const FunctionBody) Body {
        return .{ .locals = .{ .raw = self.locals }, .mode = .{ .raw = self.bodyRaw() } };
    }
};
