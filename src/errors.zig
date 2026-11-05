const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;

pub const ParseError = error{
    TooLarge, // buffer over 4 GiB
    BadMagic,
    BadVersion,
    UnknownSection, // id > 13
    SectionOrder, // rank went backwards
    DuplicateSection, // same non-custom section twice
    Truncated, // header, id, size, or payload runs past the end
    MalformedLeb, // size LEB over 5 bytes or overflowing
};

pub fn fromCursor(err: error{ EndOfStream, Overflow }) error{ Truncated, MalformedLeb } {
    return switch (err) {
        error.EndOfStream => error.Truncated,
        error.Overflow => error.MalformedLeb,
    };
}
comptime {
    // fromCursor's result must be a subset of every set that uses it. If it is not, the
    // `catch |err| return fromCursor(err)` sites fail far from here, so check it here instead.
    const from_names = @typeInfo(error{ Truncated, MalformedLeb }).error_set.error_names.?;
    const parse_names = @typeInfo(ParseError).error_set.error_names.?;
    for (from_names) |from_name| {
        var found = false;
        for (parse_names) |parse_name| {
            if (std.mem.eql(u8, from_name, parse_name)) {
                found = true;
                break;
            }
        }
        assert(found);
    }
}

pub const PayloadError = error{
    Truncated,
    MalformedLeb,
    TrailingBytes,
    InvalidKind,
    InvalidValue,
    UnsupportedFeature,
};

/// An unusable edit target: imported, or already named by the plan. The builder and encoders share
/// one error set, so callers handle one vocabulary.
pub const EditTargetError = error{
    DuplicateBody, // two bodies for one function
    DuplicateTable, // two replacements for one table
    DuplicateCustomSection, // two replacements for one custom-section selector
    ImportedFunction, // imported functions have no code entry
    ImportedTable, // imported tables have no table-section entry
};
pub const EditError = error{
    DuplicateExportName,
    InvalidExportName,
    IndexOutOfRange,
    NoInputBody, // `.keep` locals on a body with no input body
    UnknownCustomSection, // a replacement selector matched no input custom section
} || EditTargetError;
pub const EncodeError = Io.Writer.Error || error{Overflow} || PayloadError || EditError;
pub const BuilderError = error{
    MissingBody, // an added function has no body yet
    UnknownFunction, // an `.appended` ordinal `addFunction` never returned
    UnknownType, // an `.appended` type ordinal `addType` never returned
    UnknownTable, // an `.appended` table ordinal nothing returned
} || EditTargetError;
pub const PatchError = error{SectionAlreadyPatched};

pub const EmitError = EncodeError;
