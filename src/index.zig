//! Naming an entity in an index space, and turning that name into the number an encoding needs.
//!
//! An index is **input** — the input module already has it, and the number is the one the reader
//! gave back — **appended**: the n-th entity of that space this plan appends, or
//! **added import**: the n-th import of that space the plan adds. Input imports keep their places
//! and added imports go after them, before the module's own entities. Resolving one needs three
//! numbers per space: how many entities the input has, how many of them are imported, and how many
//! imports the plan adds. Nothing here knows what the plan contains, which is what lets a patch
//! stay a plan that any input of the right shape can be emitted against.
const std = @import("std");
const assert = std.debug.assert;

const spec = @import("spec.zig");
const Counts = @import("payload/Counts.zig");
const errors = @import("errors.zig");
const EncodeError = errors.EncodeError;

const kind_count = @typeInfo(spec.ExternalKind).@"enum".field_names.len;

/// The index spaces an index can name: `spec.IndexSpace`, parameterizing `Index` here.
pub const Space = spec.IndexSpace;

/// How many imports of each kind the plan adds. `emit` puts it in the `Plan` every edit resolves
/// against: an added import shifts the indices of its own space.
pub const AddedImports = struct {
    /// One count per kind, indexed by `spec.ExternalKind`.
    counts: [kind_count]u32 = @splat(0),

    pub fn add(self: *AddedImports, kind: spec.ExternalKind) void {
        self.counts[@backingInt(kind)] += 1;
    }

    pub fn count(self: *const AddedImports, kind: spec.ExternalKind) u32 {
        return self.counts[@backingInt(kind)];
    }
};

/// One space's input layout, plus the imports the plan adds to it. This is the whole context an
/// index resolves against.
pub const Layout = struct {
    input_imported: u32,
    input_total: u32,
    added_imports: u32,

    pub fn of(
        counts: *const Counts,
        kind: spec.ExternalKind,
        added_imports: *const AddedImports,
    ) Layout {
        return .{
            .input_imported = counts.importedCount(kind),
            .input_total = counts.total(kind),
            .added_imports = added_imports.count(kind),
        };
    }

    /// Types are an index space without imports.
    pub fn types(counts: *const Counts) Layout {
        return .{
            .input_imported = 0,
            .input_total = counts.typeCount(),
            .added_imports = 0,
        };
    }
};

/// An index into one `space`. The parameter is the type's identity: an index into one space cannot
/// be used where another is expected, which is the mistake that would otherwise produce a valid
/// module that calls the wrong function.
pub fn Index(comptime space_of: Space) type {
    return union(enum) {
        /// An index in the input module, as it reads today. Input imports are included.
        input: u32,

        /// The n-th defined entity of this space the plan appends, counting from 0 in call order.
        appended: u32,

        /// The n-th import of this space the plan adds. It is placed before the module's own
        /// entities, right after the input's imports.
        added_import: u32,

        /// Which space this is. It makes the type depend on its argument — without it Zig gives
        /// every instantiation the same type, and the spaces would be interchangeable again.
        pub const space = space_of;

        /// The final index. Only `.input` is checked against the input: `.appended` and
        /// `.added_import` ordinals are the plan's to hand out, not the resolver's.
        pub fn resolve(self: @This(), layout: Layout) error{IndexOutOfRange}!u32 {
            switch (self) {
                .input => |index| {
                    if (index >= layout.input_total) return error.IndexOutOfRange;
                    // An input import keeps its place: added imports follow the input's imports,
                    // before the module's own entities.
                    if (index < layout.input_imported) return index;
                    return index + layout.added_imports;
                },
                .appended => |ordinal| {
                    assert(layout.added_imports <= std.math.maxInt(u32) - layout.input_total);
                    const base = layout.input_total + layout.added_imports;
                    assert(ordinal <= std.math.maxInt(u32) - base);
                    return base + ordinal;
                },
                .added_import => |ordinal| return layout.input_imported + ordinal,
            }
        }
    };
}

pub const Type = Index(.type);
pub const Function = Index(.function);
pub const Table = Index(.table);
pub const Memory = Index(.memory);
pub const Global = Index(.global);
pub const Tag = Index(.tag);

/// An entity of any kind: what an export points at, and what anything else that names "some
/// entity" holds. The tag is the kind, so the space of the index is never ambiguous.
pub const Target = union(spec.ExternalKind) {
    function: Function,
    table: Table,
    memory: Memory,
    global: Global,
    tag: Tag,

    /// An entity the input module already has.
    pub fn input(external_kind: spec.ExternalKind, index: u32) Target {
        return switch (external_kind) {
            .function => .{ .function = .{ .input = index } },
            .table => .{ .table = .{ .input = index } },
            .memory => .{ .memory = .{ .input = index } },
            .global => .{ .global = .{ .input = index } },
            .tag => .{ .tag = .{ .input = index } },
        };
    }

    /// The n-th defined entity of `external_kind` this plan appends.
    pub fn appended(external_kind: spec.ExternalKind, ordinal: u32) Target {
        return switch (external_kind) {
            .function => .{ .function = .{ .appended = ordinal } },
            .table => .{ .table = .{ .appended = ordinal } },
            .memory => .{ .memory = .{ .appended = ordinal } },
            .global => .{ .global = .{ .appended = ordinal } },
            .tag => .{ .tag = .{ .appended = ordinal } },
        };
    }

    /// The n-th import of `external_kind` this plan adds.
    pub fn addedImport(external_kind: spec.ExternalKind, ordinal: u32) Target {
        return switch (external_kind) {
            .function => .{ .function = .{ .added_import = ordinal } },
            .table => .{ .table = .{ .added_import = ordinal } },
            .memory => .{ .memory = .{ .added_import = ordinal } },
            .global => .{ .global = .{ .added_import = ordinal } },
            .tag => .{ .tag = .{ .added_import = ordinal } },
        };
    }

    pub fn kind(self: Target) spec.ExternalKind {
        return std.meta.activeTag(self);
    }

    /// The index this target will have in the emitted module.
    pub fn resolve(
        self: Target,
        counts: *const Counts,
        added_imports: *const AddedImports,
    ) EncodeError!u32 {
        const external_kind = self.kind();
        const layout = Layout.of(counts, external_kind, added_imports);
        return switch (self) {
            inline else => |ref| ref.resolve(layout),
        };
    }

    /// The input index, when the target names one, else null. Only an `.input` index can be out
    /// of range, which is why a caller that wants to report the offending number asks for it here.
    pub fn inputIndex(self: Target) ?u32 {
        return switch (self) {
            inline else => |ref| switch (ref) {
                .input => |index| index,
                .appended, .added_import => null,
            },
        };
    }
};

const testing = std.testing;

test "Index: input indices pass through, appended ones start at the input total" {
    const layout: Layout = .{ .input_imported = 0, .input_total = 5, .added_imports = 0 };
    try testing.expectEqual(2, try (Function{ .input = 2 }).resolve(layout));
    try testing.expectEqual(5, try (Function{ .appended = 0 }).resolve(layout));
    try testing.expectEqual(7, try (Function{ .appended = 2 }).resolve(layout));

    const one: Layout = .{ .input_imported = 0, .input_total = 1, .added_imports = 0 };
    try testing.expectEqual(0, try (Function{ .input = 0 }).resolve(one));

    const none: Layout = .{ .input_imported = 0, .input_total = 0, .added_imports = 0 };
    try testing.expectEqual(0, try (Function{ .appended = 0 }).resolve(none));
}

test "Index: the last input index is valid, one past it is not" {
    const layout: Layout = .{ .input_imported = 0, .input_total = 5, .added_imports = 0 };
    try testing.expectEqual(4, try (Function{ .input = 4 }).resolve(layout));
    try testing.expectError(error.IndexOutOfRange, (Function{ .input = 5 }).resolve(layout));
    try testing.expectError(error.IndexOutOfRange, (Function{ .input = 0 }).resolve(.{
        .input_imported = 0,
        .input_total = 0,
        .added_imports = 0,
    }));
    try testing.expectError(
        error.IndexOutOfRange,
        (Function{ .input = std.math.maxInt(u32) }).resolve(.{
            .input_imported = 0,
            .input_total = 0,
            .added_imports = 0,
        }),
    );
}

test "Index: an added import goes after the input's imports, before its entities" {
    // The input has 2 imports and 3 defined entities; the plan adds 3 imports.
    // Final layout: 0,1 input imports; 2,3,4 added imports; 5,6,7 input defined entities.
    const layout: Layout = .{ .input_imported = 2, .input_total = 5, .added_imports = 3 };
    try testing.expectEqual(0, try (Function{ .input = 0 }).resolve(layout));
    try testing.expectEqual(1, try (Function{ .input = 1 }).resolve(layout));
    try testing.expectEqual(5, try (Function{ .input = 2 }).resolve(layout));
    try testing.expectEqual(7, try (Function{ .input = 4 }).resolve(layout));
    try testing.expectError(error.IndexOutOfRange, (Function{ .input = 5 }).resolve(layout));

    try testing.expectEqual(2, try (Function{ .added_import = 0 }).resolve(layout));
    try testing.expectEqual(4, try (Function{ .added_import = 2 }).resolve(layout));

    // An appended entity settles after the input's entities and the added imports.
    try testing.expectEqual(8, try (Function{ .appended = 0 }).resolve(layout));
    try testing.expectEqual(9, try (Function{ .appended = 1 }).resolve(layout));
}

test "Index: types have no imports" {
    const layout: Layout = .{ .input_imported = 0, .input_total = 0, .added_imports = 0 };
    try testing.expectEqual(0, try (Type{ .appended = 0 }).resolve(layout));
}

test "Index: every space is its own type" {
    try testing.expect(Function != Global);
    try testing.expect(Function != Type);
    try testing.expect(Type != Tag);
    try testing.expectEqual(Space.function, Function.space);
    try testing.expectEqual(Space.type, Type.space);
    try testing.expect(@sizeOf(Function) <= 8); // a tag and a u32: still cheap to copy
}

test "Target: every kind round-trips, input, appended and added import" {
    inline for (@typeInfo(spec.ExternalKind).@"enum".field_values) |value| {
        const kind: spec.ExternalKind = @fromBackingInt(value);

        const input = Target.input(kind, 3);
        try testing.expectEqual(kind, input.kind());
        try testing.expectEqual(@as(?u32, 3), input.inputIndex());

        const appended = Target.appended(kind, 4);
        try testing.expectEqual(kind, appended.kind());
        try testing.expectEqual(@as(?u32, null), appended.inputIndex());

        const added_import = Target.addedImport(kind, 5);
        try testing.expectEqual(kind, added_import.kind());
        try testing.expectEqual(@as(?u32, null), added_import.inputIndex());
    }
}

test "AddedImports: counts stay per kind" {
    var shifts: AddedImports = .{};
    try testing.expectEqual(0, shifts.count(.function));
    try testing.expectEqual(0, shifts.count(.memory));

    shifts.add(.function);
    shifts.add(.function);
    shifts.add(.memory);
    try testing.expectEqual(2, shifts.count(.function));
    try testing.expectEqual(1, shifts.count(.memory));
    try testing.expectEqual(0, shifts.count(.global));
}
