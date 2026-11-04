# wsplice

`wsplice` rewrites a WebAssembly module without re-encoding it: it copies the input through
unchanged and substitutes the payload of the sections a `Patch` names. Sections nobody asked about,
including unknown custom sections and padded LEBs, survive byte for byte.

This file is the design we are building, including the parts that are not in the tree yet.
`CONTEXT.md` beside it tracks what is implemented, what comes next, and the traps of working here.

## Fault model

- **Input bytes are untrusted.** Every read is bounds-checked by `Cursor`, so malformed input
  returns an error and never panics. Malformed input is not "corrupt code": it is handled.
- **Edits are trusted for structure, validated for invariants.** An `Edit` is chosen by the
  caller, so its shape is trusted, but an `.input` index it mentions is checked against the
  module and reported as `IndexOutOfRange` rather than written out as an invalid module. The plan's
  own `.appended` and `.added_import` ordinals are its to hand out; `wasm-validate` is the gate for
  them.
- **Writers fail.** Any `Io.Writer` call can return `WriteFailed`, and that is the only error that
  may leave bytes in the writer.
- **Everything else fails before the first byte.** `emit` runs every edit once into a counting
  writer (`measure`) before writing anything, so any other error leaves the output untouched. This
  is why `encode` must be pure: it runs twice, and the two runs must agree.
- **Body structure is not validated, except locals.** Nesting depth and branch ranges are trusted;
  `wasm-validate` is the gate. A body's `local.get` is checked when the encoder has the owning
  function's parameter count (`Body.Owner`); raw and kept instruction bytes stay unchecked.

## Diagnostics

A failure is reported twice: as the error a call returns, and — when `options.diag` is set — in
`Diagnostics`, plain data owned by the caller. It keeps the first failure: the error, the input
section and offset involved, the owning function when the failure is in a body, the name of the plan
entity when there is one, and a `Detail` with the error's numbers. An out-of-range index reports its
space, the value used and the limit, so an export target and a `call` in a body both say which space
they exceeded. `Module.parseWith` reports parse failures the same way, so a malformed input is
diagnosed from its header on; `parse` is the same call with no sink. Section offsets point at the
section frame; failures inside a payload are the reader's to report.

`Diagnostics` is kept small (a compile-time assert caps it at 128 bytes, and most of that is the
name buffer), so `Detail` grows with enums and numbers, not strings. A plan-time failure (the
builder's `patchWith`) has no input location; its detail names the added function instead.

`Detail` is error-shaped, not error-specific: an index outside a space is `out_of_range` with the
space, value and limit — including plan-time failures, where the plan's own list is the limit.
`missing_body` is the one exception: the added function exists, only its body does not, so no range
describes it; it stays a narrow variant instead of a speculative generic "missing entity". A locator
(which function's body an error came from) belongs on `Diagnostics`/`Where` beside section and
offset, not in `Detail`.

## Reading instructions vs assembling them

The instruction vocabulary is split by direction, and the names say which is which:

| | `operators.Opcode` (with `Op`) | `Body.Instr` |
|---|---|---|
| Answers | which instruction is at `at..end` | which instruction to write, with its operands |
| Produced by | reading bytes (`BodyIter`, `takeOpcode`) | the caller choosing values |
| Operands | none; they stay in the bytes | values (`index.Function`, `i32`, `f32`, ...) |
| Used for | classifying, copying a span verbatim | assembling a new body |
| Escape hatch | — (nothing is decoded) | `Instr.raw`: bytes emitted as they are |

The reader does not decode operands and does not disassemble: an `Op` is an offset pair, a depth
and an opcode, and the caller reads the operands it needs. The assembler does not echo bytes: each
`Instr` variant carries the operands, so the bytes are produced. Adding an instruction to the
assembler is one variant and one arm of the exhaustive encoder switch; `raw` covers everything
until then.

`BodyIter` stops at the function's terminating `end`: the terminator is consumed to end the
iteration but never yielded, so a caller sees instructions only. Writing the terminator is the
encoder's job, so a body can never end twice or not at all.

## Types

The type section is `vec(functype)`, and a function type is `0x60 vec(valtype) vec(valtype)`. Only
that form is representable: the GC forms (rec, sub, struct, array) are refused with
`UnsupportedFeature` like the rest of GC. `payload/types.zig` reads an entry as the encoded
one-byte value types, so a query hands out parameters and results without allocating and `Values`
decodes them lazily. `types.Signature` is the write-side shape: each of `params`/`results` is either
encoded values borrowed from an `Entry` or typed values a plan constructs. Encoded values carry
their own `value_count` (`EncodedValues`) rather than deriving it from `bytes.len`: wasm value types
can be prefixed/multi-byte, even though this library refuses those forms. `edit/AddTypes.zig` writes
that shared shape and copies the input's entries verbatim. A type the plan adds is `.appended = n`,
and `Builder.addType` hands it out.

The one-byte limit is in the reader and typed model, not in the encoded writer. A wasm value type
may be `0x63`/`0x64` followed by a heap type (abstract or concrete), so a future GC value is
multi-byte. `valtype.read` currently refuses those prefixes, `types.Entry` returns raw value bytes
with their count implied by length, and `EncodedValues.fromOneByteEntryValues` names that
assumption. If GC value types are added, `valtype` grows a `Value` union (`one_byte` or
`reference`), `takeValues` returns an `EncodedValues` with its count from the vector, and `Entry`
stores `EncodedValues` so no length is ever used as a count. The encoded `Signature` path and
`AddTypes` writer already need no change.

## Globals

A global type is `globaltype ::= valtype mut`; `payload/globals.zig` reads entries and writes one
type (`writeType`), and `imports.Global` is that same type. `edit/AddGlobals.zig` appends globals
from a global type plus a constant expression, copying old entries verbatim; `Builder.addGlobal`
hands out the `.appended` index. Nothing checks that an initializer produces its declared type:
`wasm-validate` is the gate.

## Tables

The table section is `vec(tabletype)`, and `tabletype ::= reftype limits`. A table's reference type
is one abstract heap type, the same shorthand a global's value type uses; `payload/tables.zig` reads
entries (and exposes each one's exact bytes) and writes one. `edit/SetTables.zig` replaces the type
of named input tables: imported tables have no entry here (`ImportedTable`), a table takes one
replacement (`DuplicateTable`), and entries the plan does not name are copied verbatim.
`Builder.setTable` records a replacement:

```zig
try builder.setTable(allocator, .{ .input = 0 }, .{
    .reftype = .func,
    .limits = .{
        .flags = .{ .has_max = true, .is_shared = false, .is_64bit = false },
        .min = 2,
        .max = 8,
    },
});
```

This sets a table's type and limits, not its contents: what a table holds is the element section,
which is not edited yet. The table section never emits an index, so an added import does not change
it; the table's position in its index space is what shifts. Changing an existing table's reference
type can invalidate element segments or instructions that use it; the caller owns that, and
`wasm-validate` gates it. `Query.tableType(table)` returns an imported or defined table's type, or
null, so a caller can check that a table exists and what its reference type is before planning.

## Code edits

An entry in the code section is `size:u32 func`, which makes it self-delimiting: an edit copies an
entry it does not change without reading its instructions, and only a rewritten body is re-encoded.
The frame reader is `payload/code.zig`, one body is `payload/Body.zig`, the instructions are
`operators.BodyIter`, and `edit/SetBodies.zig` writes the section from them.

A code entry belongs to a defined function, so a function index resolves to an entry by subtracting
the input's imported function count. Imported functions have no body and are refused. At this level
nothing checks that the number of appended bodies matches the functions the plan adds: the builder
does (`MissingBody`), and `wasm-validate` does for a patch built by hand.

### Locals

A `func` declares only its own locals; its parameters are in the function's type, not the code
entry. Validation still puts both in one index space, parameters first:

```
local.get index:  0 .. p-1        p .. p+n-1
                  parameters       declared locals (the vector)
```

A declaration is a run count and a type, exactly like the binary vector:

```zig
pub const LocalDecl = struct { count: u32, valtype: spec.ValueType };
```

`Body.locals` is one of:

| Mode | Vector written | Use |
|---|---|---|
| `.keep` | the input body's vector, verbatim | the new instructions use the locals the function already has |
| `.replace = declarations` | exactly these declarations | a body with its own locals |
| `.append = declarations` | the input's runs, then these | the new instructions need extra scratch locals |
| `.raw = bytes` | these bytes, verbatim (the whole vector) | a queried vector, or a copy from elsewhere |

`Locals.raw` is the complete vector: run count, then runs. `.keep` and `.raw` copy bytes, so a padded
LEB survives; `.replace` and `.append` write declarations with canonical count LEBs, one run per
declaration. `.append` never merges a new run into the input's last one, and `.replace` never merges
two of its declarations, so equal adjacent runs can stay separate: valid, not canonical.

`.keep` requires an input body. On a function the plan adds there is nothing to keep, so it is
`error.NoInputBody`: a silent empty vector would hide the mistake. `.append` without an input body
writes its own declarations, which is how a new function states its locals; `.replace` and `.raw`
always work.

A local index is checked against parameters + the declared vector when the body knows its owner.
`Body.Owner` carries `emitted_function` (the owning function's final index in the emitted module)
and `parameter_count`; `SetBodies` supplies both for a replacement or an added body, resolving the
function's type from the input or, for a type the plan adds, from `Plan.added_types`. A body encoded
on its own has no owner, so its local indices are not checked. The bound counts `.keep` and
`.append` input runs and `.raw` vectors by parsing them; `.replace` sums its declarations. The
diagnostic records the function (`Where.function`, not `Detail`) and puts the local index in
`out_of_range` with `space = .local`. `.raw` and `.keep` instruction bytes are opaque and stay
unchecked, like branch labels and operand types.

### Bodies

A body says how to produce the locals and how to produce the instructions:

```zig
pub const Body = struct {
    locals: Locals = .keep,
    mode: Mode,
};

pub const Mode = union(enum) {
    replace: []const Instr,
    rewrite: Rewriter,   // run a caller's code over the input instructions
    raw: []const u8,     // instruction bytes, written as they are
};
```

The terminating `end` belongs to none of the modes: the encoder writes it after the instructions, so
every emitted body is terminated. The entry's size prefix is measured from the produced bytes, never
inherited from the input.

The encoder takes the input body as `Body.Input` — its locals vector and its expression — so
`.keep` locals and `.rewrite` have something to work on. An added function has no input body, and
`Body.encode` (a body on its own) has none either.

`Mode.raw` follows the escape-hatch contract, the same as `Instr.raw`: instruction bytes without the
final `end`, self-contained and depth-neutral (no `block`/`loop`/`if`/`end` that escapes, no branch
out). The bytes are not parsed, so a body using opcodes the reader refuses (GC, legacy EH) can still
be copied, and indices inside the bytes are never remapped.

A function the plan adds has no input body: `.replace` and `.raw` write what they are given,
`.rewrite` gets an empty instruction stream (so it can only emit), and `.keep` locals is the error
above.

### Rewriting

A rewriter drives the input body and writes through a sink; it never sees a writer:

```zig
// the user's type
pub fn rewrite(self: *const T, body: operators.BodyIter, out: *Body.Out) EncodeError!void;

// Body.Out, declared in payload/Body.zig
pub const Out = struct {
    pub fn write(self: *Out, instrs: []const Instr) EncodeError!void,
    pub fn keep(self: *Out, op: operators.Op) EncodeError!void,
};
```

`Out` is concrete and made fresh for each body per pass, holding the writer, the input bytes (for
`keep`), `Counts`, the `Plan`, the owning function's emitted index, the precomputed local limit, and
`Options`. `keep` copies the input instruction's span byte for byte; `write` encodes `Instr`s,
resolves their `index.*` against `Counts` and `Plan.added_imports`, and checks `local.get` against
the precomputed bound. A rewriter only needs `write`/`keep`; the rest is encoder context.
`Rewriter.from(&value)` erases the user type to one function pointer plus a context pointer: one
indirect call per callback, and the callback is a direct call inside that shim. The callback is
`pub` because the shim lives in `Body.zig`.

The context is `*const` and must outlive `emit`; each run gets a fresh `Out` and a fresh iterator,
so the callback has to be deterministic. Validation (depth back to zero, `br` in reach) is deferred.
The local bound lives in `Out.write`; `Out.keep` copies bytes, so kept instructions are never
re-checked.

### Copying

Copying a body needs no rewriter: the query hands out the raw pieces, and a body is

```zig
.{ .locals = .{ .raw = source.locals }, .mode = .{ .raw = source.bodyRaw() } }
```

which is exactly `source.body()` (see Queries). The same shape copies from another module. Copied
bytes keep the indices they had and are never remapped: a copy is safe in the same module, but an
added import shifts those indices, so a copy and an import in one plan are the caller's
responsibility — the remapper cannot see bytes.

## Queries

Reading is not building, so queries do not go through the builder:

```zig
const query = try module.query(.{});          // Counts computed once
const info = try query.functionInfo(function); // ?FunctionInfo
const body = try query.functionBody(function); // ?FunctionBody
const type_index = try query.functionType(function); // ?index.Type
const signature = try query.functionSignature(function); // ?types.Signature
const table_info = try query.tableInfo(table); // ?TableInfo
```

`Query` holds the module and its `Counts`:

```zig
pub const Origin = enum { imported, defined };

pub const FunctionInfo = struct {
    origin: Origin,
    type_ref: ?index.Type,
    signature: ?types.Signature,
    body: ?FunctionBody,
};

pub const TableInfo = struct {
    origin: Origin,
    table_type: ?tables.Type,
};

pub const Query = struct {
    module: *const Module,
    counts: Counts,

    pub fn functionInfo(self: *const Query, function: u32) PayloadError!?FunctionInfo;
    pub fn tableInfo(self: *const Query, table: u32) PayloadError!?TableInfo;

    pub fn functionBody(self: *const Query, function: u32) PayloadError!?FunctionBody;
    pub fn functionType(self: *const Query, function: u32) PayloadError!?index.Type;
    pub fn functionSignature(self: *const Query, function: u32) PayloadError!?types.Signature;
    pub fn typeSignature(self: *const Query, type_index: u32) PayloadError!?types.Signature;
    pub fn tableType(self: *const Query, table: u32) PayloadError!?tables.Type;
};
```

`FunctionInfo` is the planning query: it carries the origin and, when available, the type,
signature and body in one value. `body == null` means imported or a defined function with no code
entry; `signature == null` means the type index is absent or the type section is inconsistent.
`TableInfo` combines origin and table type, so a caller can check `.defined` before `setTable`: the
table-section edit cannot change an imported table. The targeted methods stay for callers that need
one fact and should not pay for the rest.

Finding function `n` walks the code section to its ordinal among defined functions; a loop over many
functions is `O(n^2)`, which is fine for the handful a plan touches, and an iterator can be added
later. Query values borrow the module's bytes, so the module must outlive them.

```zig
pub const FunctionBody = struct {
    locals: []const u8,   // the whole locals vector
    expression: Cursor,   // instructions plus the terminating `end`

    pub fn instructions(self) operators.BodyIter; // fresh; terminator not yielded
    pub fn bodyRaw(self) []const u8;              // instructions, `end` excluded
    pub fn body(self) Body;                       // raw locals + raw instructions
};
```

`functionBody` checks the expression's terminator byte, so `bodyRaw` and `body` are total. It does
not decode instructions: a body can be read as bytes and copied even when `operators` refuses one of
its opcodes.

`functionSignature` resolves the type index and returns a `types.Signature` with encoded
parameters/results; `typeSignature` reads an input type directly, for callers starting from an
index. Both return null for an absent entry (function, type, or a function whose type index the
type section does not have). Query signatures are always encoded, decoded on demand without
allocation:

```zig
var params = types.Values.init(signature.?.params.encoded.bytes);
while (params.next()) |value| { ... }
```

`functionType` stays index-only: its main use is `builder.addFunction`, and reading the type section
there would turn an inconsistent type index into a query error instead of an index the caller can
inspect. Signatures are the separate query.

## Building a plan

The builder only accumulates edits; it never reads a module. A function and its body are added in
separate calls because the function's reference is needed inside its own body (recursion,
self-reference):

```zig
const wrapper = try builder.addFunction(allocator, function_type);
try builder.setBody(allocator, wrapper, .{
    .locals = .{ .replace = &.{} }, // the new function declares no locals
    .mode = .{ .rewrite = ... },
});
const patch = try builder.patch();
```

`addFunction` appends a function declaration and returns its `.appended` ordinal; `setBody` stores
one body per function, for an input function or an appended one, in any call order. `setBody`
rejects an `.appended` ordinal that was never added (`UnknownFunction`) and a second body for one
function (`DuplicateBody`). `patch()` is fallible: an added function with no body is
`error.MissingBody`, because emitting nothing would shift the later bodies onto the wrong functions.
It builds the function section edit and the code section edit together.

The declarations are `edit/AddFunctions.zig`: the input's entries are copied verbatim, `.input`
type indices are checked against the input's type count, and `.appended` ones resolve after it. A
function's body is `SetBodies`, as before; the builder only makes sure the lists line up.

`patchWith(options)` is `patch` with a diagnostics sink. A missing body records its `.appended`
ordinal in `Detail.missing_body`: the failure is in the plan, not in an input byte. Only `patch`
takes a sink: `setBody`'s errors are immediate and the caller still holds the ordinal it passed, so
threading `Options` through every builder call would buy nothing.

`addType` appends a new signature and returns its `.appended` ordinal, which `addFunction` can name:

```zig
const wrapper_type = try builder.addType(allocator, .{
    .params = &.{.{ .number_or_vector = .i32 }},
    .results = &.{.{ .number_or_vector = .i32 }},
});
const wrapper = try builder.addFunction(allocator, wrapper_type);
```

Until a type is added, a new function reuses an existing type index, typically the one
`query.functionType` returned. `patch` checks that every `.appended` type a function or import
descriptor names was really added (`UnknownType`), so the emitted type index is valid before
`wasm-validate` ever sees it.

Adding an import is a section edit plus a shift, not a body edit. The binary shape is
`import ::= name name importdesc`; the names are borrowed bytes, and a function or tag descriptor
carries a type index. `edit/AddImports.zig` appends entries, copies the old ones verbatim (padded
LEBs included), writes the count canonically, and resolves a type index like a function declaration
does. `Builder.addImport` adds one and hands back the target that names it:

```zig
const log = try builder.addImport(allocator, "env", "log", .{ .function = .{ .input = 3 } });
try builder.addExport(allocator, "log", log);
```

An added import is placed before the module's own entities, so it is not one of the plan's
`.appended` ordinals; naming it takes the third variant of an index, `.added_import = n`: the n-th
import of that kind the plan adds.

An import of a kind shifts the indices of that space, and only that space: a memory import moves
memory indices and leaves function indices alone. Type indices never shift. `Plan.fromPatch` builds
the plan-wide context from the patch; `emit` and callers resolving indices use it.
`Plan.added_imports` says how many imports of each kind the plan adds; `Plan.added_types` and
`Plan.added_functions` carry the added signatures and function types, which the body encoder uses
for an added function's parameter count. `index.Layout` combines the import counts with the input's
imported and total counts, and every emitted index resolves through it:

| index | final number |
|---|---|
| `.input = i` | an input import keeps `i`; an input defined entity becomes `i + added imports` |
| `.appended = n` | `input total + added imports + n` |
| `.added_import = n` | `input imported + n` |

Only `.input` is checked against the input; the plan's own ordinals are its to hand out, and
`wasm-validate` is the gate for them. Raw, kept and untouched bytes are never remapped: their
indices are the caller's. A raw edit for the import, type or function section is opaque, so its
contribution to `Plan` is empty. Remapping those bytes would mean parsing and rewriting every
section, which this design deliberately does not do.

The input's own bytes are not rewritten either, so an import-only plan is valid only when the
input's own references — an export, a start function, an element segment, a body — do not name a
shifted space, or are known to be correct after the shift. That is the caller's part, like every
other byte the library copies through.

## Resolving indices outside emit

`Plan`, `Counts` and `index.Layout` are public, so a caller can resolve a symbolic target without
writing the module:

```zig
const counts = try Counts.of(&module, options);
const plan = Plan.fromPatch(&patch);

const target_final = try target.resolve(&counts, &plan.added_imports);
const function_final = try added_function.resolve(
    index.Layout.of(&counts, .function, &plan.added_imports),
);
const type_final = try added_type.resolve(index.Layout.types(&counts));
```

- `.input` is checked against the input's counts.
- `.appended` and `.added_import` are the plan's ordinals, not checked by resolution.
- `.added_import` is not valid for a type index; types have no imports.
- A raw edit for the import, type or function section contributes nothing to `Plan`, so its
  indices stay caller-owned.
- `emit` uses the same `Plan.fromPatch` and `Counts`, so these numbers match the emitted module.

There is no `Resolver` wrapper today. Keeping `Plan`/`Counts`/`Layout` as the public pieces lets a
caller use them for more than one resolution, and leaves room for a richer full-pass or
disassembly context later.

## Deviations from TigerStyle

Taken deliberately, each with a reason and a point at which to revisit it. The rule quoted is the
one from `TIGER_STYLE.md`, a verbatim copy of <https://tigerstyle.dev> kept beside this file so the
rules and the deviations from them live together; the deviation is what this code does instead.

| Rule | Deviation | Why | Revisit when |
|---|---|---|---|
| snake_case for files and functions | Zig standard convention: `Cursor.zig`, `Module.zig`, `readUleb` | Familiarity for Zig readers; the doc's own escape hatch is "for the rest, follow the Zig style guide" | never, unless the project leaves Zig |
| 100 columns, without exception | `tests/` is exempt; the guard in `tests/style.zig` covers production files only | The test pass has not happened yet; a guard that fails on day one gets deleted | the test cleanup pass, then add `tests/` to the guard |
| no abbreviations | inline tests in production files keep short locals (`c`, `it`, `m`) | Test prose is read differently from library code, and renaming them is churn with no safety payoff | the same test cleanup pass |
| explicit options at call sites | tests pass `.{}` | `.{}` is the whole point of an all-defaults struct; spelling out eight nulls hurts reading | never for `Options`; keep spelling out options that are not the default |
| two assertions per function, average | about one per function | Many functions are accessors where a second assertion would be invented, not found | when a function grows a second real invariant |
| no dynamic allocation after init | the `Builder` takes an allocator per call, and `init` takes none | A library cannot size itself from a caller's input the way a server can; the rule that matters, "nothing allocates in the emit path", holds | if the `Storage` (caller-provided slices) route is added |
| value arguments over 16 bytes as `*const` | sinks, borrowed views and failure descriptors stay by value | See below | a view gains an invariant that a copy could break |

### By-value arguments over 16 bytes

The rule is "if you don't mean a function argument to be copied when passed by value, and if the
argument type is more than 16 bytes, then pass the argument as `*const`". Three kinds of parameter
stay by value deliberately; everything else over 16 bytes is `*const`.

**Sinks copy because storing the copy is the point.** `Patch.setPayload` takes `Edit` by value:

```zig
pub fn setPayload(self: *Patch, id: SectionId, edit: Edit) PatchError!void
    ...
    slot.* = edit; // the copy is the whole point of the function
```

`setPayload` is a sink, not a source. Passing `*const` would only move the copy (`slot.* = edit.*`)
and would make the signature suggest aliasing that does not exist: the patch holds its own copy, so
a caller that mutates its `Edit` afterwards cannot affect the patch either way.

The call sites carry the argument. There are 25, 21 of them in tests, nearly all handing over a
temporary: `p.setPayload(.type, raw("t"))`. Under `*const` every one becomes `&raw("t")` or
`&.{ .add_exports = ... }`. That would compile — `&temporary` is legal in this Zig version — so this
is a readability decision, not a feasibility one.

`Builder.addGlobal` takes `Global` (over 16 bytes) by value, `Builder.setBody` takes `Body` (48
bytes), `Builder.addImport` takes its descriptor, `Builder.addType` takes `Signature` (over 16
bytes), and `Builder.setTable` takes `tables.Type` (over 16 bytes), for the same reason: the list
stores a copy, and that copy is the call's job.

**Views are copied windows.** `Cursor` (24 bytes) is copied into every payload iterator on purpose:
the iterator advances its own copy and the caller's cursor must not move. `BodyIter` (32) is one
iteration's state; a rewriter gets a fresh one per pass, so passing it by value is the contract.
`Body.Input` (40) is built at the call site from the entry being replaced, read once, and dropped.

**Descriptors are read and forgotten.** `Diagnostics.Where` describes one failure; every call site
hands over a literal.

Everything else over 16 bytes is `*const`: method receivers (`Body`, `Query`, `FunctionBody`),
`code.Entry` inside a constructor, the `Plan` (`Edit.encode`, `measure`, `writeSection`,
`Body.encodeWith`, `SetBodies`), and `Edit` wherever it is only read (`Edit.encode`,
`Edit.encodedLen`, `writeSection`, `spliceSection`, `insertSection`). `Patch.get` returns
`?*const Edit` (a borrow with a documented lifetime) precisely because it is the source side of the
same split. A loop over a slice captures `|*element|` when the element is over 16 bytes, so the
copy is not made once per step.
