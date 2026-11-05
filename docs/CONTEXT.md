# wsplice context

Working notes for whoever (human or AI) picks this up after a context reset. The design is in
`docs/ARCHITECTURE.md`; this file is the state, environment, workflow, and traps. If you read only
one thing, read `docs/ARCHITECTURE.md`, then run the tests below and check `git status`.

## Where things are

- This is the standalone wsplice repository. The library source is under `src/`; docs live at the
  repository root under `docs/`.
- Public module: `src/wsplice.zig`. Tests: `src/tests/`; fixtures: `src/tests/fixtures/`; style
  guard: `src/tests/style.zig`.
- Docs: `docs/ARCHITECTURE.md` (design, including not-yet-implemented parts),
  `docs/TIGER_STYLE.md` (verbatim rules), this file.
- There is no host application or crate here; wsplice was extracted from a larger project.
- Feature state: stages through 13a (`SetTables`) and 11 (local bounds), plus custom-section
  query/edit/remove and dylink.0 needed handling. Next is 13b (element segments) when needed. The old
  stage numbers are kept only for continuity.

## How to continue

1. Read `docs/ARCHITECTURE.md`, then this file.
2. `git status --short` from the repository root.
3. Run both test commands below; **524/524** is the expected baseline.
4. Next is 13b (element segments / `addElementSegment`), deferred until the caller is ready; 11,
   custom sections, and dylink.0 needed handling are done.

## Build, test, check

From the repository root:

```
zig build test --summary all -Doptimize=debug
zig build test --summary all -Doptimize=safe
zig fmt src
zig fmt --check src
```

- `zig` is found on `PATH` (Zig 0.18 development build).
- The target defaults to the host, so no `-Dtarget` is needed for normal tests. Pass `-Dtarget`
  only for a cross build.
- Wabt tools are found on `PATH`: `wasm-validate`, `wasm-objdump`, `wat2wasm`
  (`--enable-threads` for atomics).
- Last green run: **524/524** in both modes; the 100-column guard in `src/tests/style.zig` covers
  41 production files.

## Conventions

- A file with top-level fields is a type (`Builder.zig`, `Body.zig`); a namespace is snake_case
  (`operators.zig`).
- `payload/` = codecs for structures inside a payload, both directions. `edit/` = writers of one
  whole section payload. `Body` is payload; `SetBodies` is the edit.
- A new production file must be added to `src/tests/style.zig` and to a test file imported from
  `src/tests/all.zig`.
- `src/wsplice.zig` groups its exports: types first, then namespaces/module imports, then functions,
  without section comments or blank separators. Its test block only imports `tests/all.zig`; that
  registry is where every test module is named.
- Assertions are contract checks, not input validation: section identity, span bounds, u32 widths,
  selector occurrence and post-write run positions have asserts; accessors do not get invented
  assertions. The two-per-function average remains a documented deviation, not a target to fake.
- Supply rule: non-sink arguments over 16 bytes are `*const` (e.g. `Selector`, `Entry`). Sinks
  (`Builder` storing `Source`), borrowed views (`Module.Section`) and failure descriptors
  (`Diagnostics.Where`) are the documented exceptions in `ARCHITECTURE.md`.
- Edits borrow: slices and rewriter contexts must outlive `emit`. `encode` runs twice (measure, then
  write), so it must be pure. Nothing allocates in the emit path; the builder allocates at plan
  time and is unmanaged (`init` takes no allocator).
- One edit per non-custom section; `Patch.setPayload` refuses a second. Custom sections use
  `Patch.custom`, because they repeat and have no slots.
- `Diagnostics` keeps the first failure; edits fail before writing (the measure pass runs first).
- Work stepwise: implement, summarize the new signatures, wait for a go before the next stage.

## Public surface and resolving indices

`src/wsplice.zig` re-exports `Body`, `BodyIter`, `Builder`, `Counts`, `Cursor`, `CustomEdit`,
`CustomPlacement`, `CustomSelector`, `CustomSource`, `Diagnostics`, `Edit`, `Module`, `Options`,
`Patch`, `Plan`, `Query`, `index`, `ValueType`, `emit`, `outputLen`, and `custom.dylink`.

`Plan.fromPatch`, `Counts.of`, and `index.Layout` are public so a caller can resolve a symbolic
target without exporting a separate resolver:

```zig
const counts = try Counts.of(&module, options);
const plan = Plan.fromPatch(&patch);

const target_final = try target.resolve(&counts, &plan.added_imports);
const function_final = try added_function.resolve(
    index.Layout.of(.function, &counts, &plan.added_imports),
);
const type_final = try added_type.resolve(index.Layout.types(&counts));
```

- `.input` is checked against the input counts.
- `.appended` and `.added_import` are the plan's ordinals; resolution does not prove the builder
  handed them out.
- `.added_import` is invalid for a type reference; types have no imports.
- A raw import/type/function edit contributes nothing to `Plan`, so its indices are caller-owned.
- `emit` uses the same `Plan.fromPatch` and `Counts`, so these numbers match the output.
- There is no `Resolver` today. Keeping `Plan`/`Counts`/`Layout` public leaves room for a richer
  full-pass or disassembly context later.

## Implemented today

- Core: `Module`/`SectionIter`, `Cursor`, two-pass `emit`, `Patch`, `Options`, `Raw`, `AddExports`
  (slice only), `AddFunctions`, `AddImports`, `AddTypes`, `AddGlobals`, `SetBodies`, `SetTables`;
  `Builder`, `Query`, `Counts`, `Plan`, `index`.
- `Diagnostics` keeps the first failure: error, section, offset, owning function, name, and a
  `Detail` (an out-of-range index's space, value and limit; a missing body's ordinal; a custom
  selector's occurrence). The owning function is the final function index in the emitted module.
  `Module.parseWith` diagnoses parse failures; `parse` is the same call with no sink.
- `Plan` (`src/Plan.zig`): the plan-wide context every edit resolves against: `added_imports`,
  `added_types`, `added_functions`. `Plan.fromPatch(patch)` builds it from the patch; a raw edit
  for one of those sections contributes nothing.
- `Counts` (`src/payload/Counts.zig`): `of(module, options)`, `total(kind)`,
  `importedCount(kind)`, `typeCount()`.
- `index`: `Index` = `input` / `appended` / `added_import`, `Target` (the kind-tagged entity
  reference), `AddedImports` (added imports per kind), `Layout` (input imported/total + added
  imports). An input import keeps its index, an input defined entity shifts by the added imports,
  an appended entity settles after both, and an added import lands after the input's imports.
  Types never shift.
- `payload/`: `valtype`, `limits` (read and write), `tables` (table types, read/write, entry
  bytes), `imports`, `exports`, `functions` (one type index per defined function), `types`
  (function types; encoded value bytes with lazy `Values`; `Signature`/`SignatureValues`/
  `EncodedValues` for encoded-or-typed writes), `globals` (global types, read/write, entries),
  `const_expr`, `operators` (`BodyIter` stops at the depth-0 `end`: it is consumed, never yielded,
  and trailing bytes are `TrailingBytes` on the same call), `Counts`, `code`
  (`Entry{bytes, locals, body}`), `Body` (`LocalDecl`; `Locals` = keep/replace/append/raw; `Mode` =
  replace/rewrite/raw; `Out` `write`/`keep`; `Rewriter.from`; `Input{locals, body}`;
  `Owner{emitted_function, parameter_count}`; local checks when the owner is known).
- `Query` (`module.query(.{})`): `functionInfo` → `?FunctionInfo` (`origin`, `type_ref`,
  `signature`, `body`; body null for imports and defined functions with no code entry),
  `tableInfo` → `?TableInfo` (`origin`, `table_type`); targeted `functionBody` → `?FunctionBody`
  (`locals`, `expression`; `instructions()`, `bodyRaw()`, `body()`), `functionType` → `?index.Type`,
  `functionSignature` / `typeSignature` → `?types.Signature` (encoded params/results), `tableType`
  → `?tables.Type`. Imported tables are included; null means an absent index. `initWithCounts`
  reuses counts a caller already has. Body copying goes through `Body{locals.raw, mode.raw}` and
  `SetBodies`.
- Custom sections: `Query.customSections()` iterates `CustomSection{name, data, section}` in file
  order; `customSection(name)` returns the first exact-name match. Names/data are borrowed and
  arbitrary; no allocation. `payload/custom.zig` owns only the name/data framing. Typed codecs live
  under `custom/` and take data, not a name: `custom/dylink.zig` is implemented (`read`, `Update`,
  `Info`); `custom/name.zig` is not implemented yet.
- Custom edits: `Patch.custom` is a borrowed `[]const CustomEdit`; `custom/edit.zig` holds the
  edit shape, `custom/apply.zig` holds emit-side matching, measurement and writing. `Source`
  (`bytes` or streaming `rewrite`), `Placement` (`start`/`end`), `Selector`, and `Edit`
  (`append`/`replace`/`remove`). `Builder.addCustomSection` (with placement),
  `setCustomSection`, and `removeCustomSection` append to that list. A replacement preserves the
  section's position; a removal deletes the whole section frame; a start append goes after the
  8-byte header; an end append goes after all input bytes. Selectors are exact name bytes plus a
  0-based occurrence among **input** custom sections; they are input-relative and do not renumber
  after removals. A selector may have one replace or remove; appends do not target input selectors.
  Names, byte sources and rewriter contexts are borrowed until `emit`, and a rewriter context must
  have a stable address. `UnknownCustomSection` is emitted when an input selector has no match;
  duplicate selectors are `DuplicateCustomSection`. `Diagnostics` records the custom name and
  occurrence.
- `custom/dylink.zig`: dylink.0 subsection framing (mem_info, needed, export/import info, unknown
  kinds); kinds are a non-exhaustive `enum(u8)` ending in `_`, so adding a known kind is a field +
  switch branch and unknown kinds stay opaque. `read` exposes `mem_info` and a validated `Needed`
  view whose `count()`/`iterator()` parse the borrowed `encoded` vector on demand. `NeededSource` has `.none`, `.names`, and `.encoded`;
  `Info.needed: NeededSource = .none`, and `Update.needed: ?NeededSource = null` where null means
  keep. `.none` removes/omits, `.names` rewrites from a borrowed list, `.encoded` copies a validated
  complete `vec(name)` payload. `Update.write` rewrites mem_info and needed in place (appending
  needed when absent) and copies every other subsection byte-for-byte; `Info.write` creates mem_info
  plus the chosen needed source. No allocator, no returned buffer. Missing/duplicate mem_info or
  duplicate needed is `PayloadError.InvalidValue`; encoded needed is validated before writing;
  arbitrary names work because `read`/`write` do not check the section name.
- `edit/SetBodies.zig`: existing bodies by input function index, added bodies positional; hands the
  input entry's locals and expression to the body; refuses imported functions, out-of-range indices,
  duplicate bodies, and `.keep` locals on an added body (`NoInputBody`); copies untouched entries
  verbatim. It builds each body's `Body.Owner` from `Plan`/`Query`: the final function index and the
  parameter count, so `local.get` is checked against parameters + declared locals.
- `edit/SetTables.zig`: replaces the type (reftype + limits) of input defined tables; imported tables
  are `ImportedTable`, one replacement per table (`DuplicateTable`), untouched entries copied
  verbatim, count canonical. `Builder.setTable` records replacements.
- `edit/AddFunctions.zig`: appends function declarations, copies the old entries verbatim, checks
  type indices against the input's type count.
- `edit/AddTypes.zig`: appends function types from shared `types.Signature` values (encoded or
  typed params/results), copies the old entries verbatim; GC type forms are refused
  (`UnsupportedFeature`).
- `edit/AddImports.zig`: appends imports (names borrowed, function/tag type indices symbolic),
  copies the old entries verbatim, canonicalizes the count; its writer refuses reserved limits flags
  and 32-bit values that do not fit, with a diagnostic.
- `Builder` v2: `addType`, `addImport` (→ an added-import target), `addFunction`, `setBody` (any
  call order; `UnknownFunction` / `DuplicateBody` / `ImportedFunction`), `setTable` (`UnknownTable` /
  `ImportedTable` / `DuplicateTable`), `addCustomSection` (placement) / `setCustomSection` /
  `removeCustomSection` (`DuplicateCustomSection`; missing selector is emit-time
  `UnknownCustomSection`), fallible `patch` (`MissingBody`, `UnknownType` for an `.appended` type
  the plan never added; `patchWith` names the ordinal in the detail), plus the v1 global/export
  additions.
- `Edit.encode`/`encodedLen` take the plan's `*const Plan`; `emit` builds it via
  `Plan.fromPatch`. Raw, kept and untouched bytes are never remapped; a raw edit for the
  import/type/function section contributes no plan values.
- `Patch.custom` is a separate borrowed list (`custom/edit.zig`); `emit` delegates its application
  to `custom/apply.zig`: `.start` appends after the header, `.end` appends after all input bytes,
  and replacements stay in place. Streaming sources write directly to the output; no replacement
  buffer exists.
- Errors: `EditTargetError` is shared by `BuilderError` and `EditError` for imported/duplicate body,
  table, and custom-section targets; `UnknownCustomSection` is in `EditError`.
- Missing entirely: element segments (`addElementSegment`), `addTable`, table instructions
  (`table.get/set/grow/size`), `custom/name.zig`, and support for GC/multi-byte value types or GC
  type forms.

## Agreed design, next stage (see `docs/ARCHITECTURE.md`)

1. **13b** — element segments, when ready: `payload/elements.zig` (flags `0..7`),
   `edit/AddElements.zig`, and `Builder.addElementSegment` with `table: index.Table`,
   `offset: const_expr.Expr`, and `functions: []const index.Function`. Appends active segments,
   copies old ones verbatim, and resolves table/function refs through `Plan`. The table slot is a
   runtime `i32`, not an `index.*`. `addTable` and table instructions follow if wanted.

The index/remap, table-type, local-bound, Query-info, and shared-signature work is done. A `Resolver`
wrapper was deliberately not added: `Plan`/`Counts`/`Layout` are public for now, and a full-pass or
disassembly context can wrap them later.

Deferred: element segments, `addTable`, table instructions; GC type/value types; imported-table
`setTable` (import limits are not editable); `custom/name.zig`; the `AddGlobals` options struct;
test abbreviation cleanup.

## Comment style

Production `src/**/*.zig` comments are ASCII-only and follow Zig stdlib style: concise, and only
where they explain why, an algorithm, binary formatting, a lifetime, ownership or an invariant.
Do not restate code, narrate history, or duplicate `ARCHITECTURE.md`; use prose and inline code for
wire shapes, because BNF belongs in `ARCHITECTURE.md`. Test comments are test methodology, not
library documentation. Docs may use UTF-8; `TIGER_STYLE.md` is a verbatim copy.

## Traps remembered

- Git lives at this repository's root; run it from there.
- PowerShell `-replace` is case-insensitive and has corrupted identifiers here; use `-creplace`.
- A rewriter's `rewrite` method must be `pub`: `Rewriter.from` instantiates its shim inside
  `Body.zig`, which is another file.
- A rewriter context is borrowed until `emit` and must have a stable address. A `Transform`
  declared inside a loop iteration is overwritten by the next iteration while `Rewriter` still
  holds its address; `setBody` succeeds, then `emit` reads stale fields. This often appears as an
  unrelated local-index error in another function, or as output that validates but behaves wrong.
  Allocate per-function contexts with an arena or keep them in an outer array. `arena.create` is
  the usual fix.
- Custom sources have the same lifetime: `CustomSource.from(&changes)` stores a context pointer.
  Keep `changes`/`info` in an outer scope or an arena until `emit`. The source itself writes
  directly to the output, so do not allocate a replacement buffer.
- Custom matching scans custom sections only, not the whole module. A section whose name no edit
  targets skips the occurrence scan. Byte sources compute length arithmetically; streaming sources
  run during measure and again for write-side length/data. Building an occurrence index would need
  allocation or caller storage, so it is deferred until custom-section counts justify it.
- Custom replacement selectors are name + 0-based occurrence, not offsets. The emit pass parses
  input custom names to match them; a patch with only appends does not parse names and leaves
  opaque custom payloads untouched. Occurrences are input-relative: removing an earlier section
  does not renumber a later selector, and appended sections never count. `UnknownCustomSection` is
  emit-time because the builder has no module; duplicate selectors are rejected by both the builder
  and emit.
- Custom names, needed names/encoded bytes, and byte sources are borrowed until `emit`; streaming
  source contexts must also have a stable address. A removal has no source. `remove` is an explicit
  edit variant, not an empty replacement: an empty source leaves an empty custom section behind,
  while remove deletes the frame. Copying a dylink needed vector from another module borrows that
  module's bytes, so the source module must outlive `emit` as well.
- `Detail.custom_section` is only the occurrence; the custom name is in `Where.name`. Do not add a
  dylink-specific diagnostic detail: a malformed dylink payload is `PayloadError.InvalidValue`, and
  the section name/offset are generic.
- `custom/dylink.zig` is name-agnostic. `dylink.read`, `Update.write`, and `Info.write` must not
  check for `"dylink.0"`; callers may use the same payload under an arbitrary custom name.
- `custom/name.zig` is still unimplemented; do not list it as available until it exists.
- `Body.Input.body` is a `Cursor` whose `bytes` are the module bytes, so `Op.at`/`Op.end` slice
  correctly in `Out.keep`. A cursor over a separate expression buffer only works when that buffer is
  the module.
- An added body's rewriter sees a stream of just the terminator: `next()` returns null, not
  `Truncated`, because a `BodyIter` needs a final `end` even when it yields nothing.
- `Module` ↔ `Query` are mutual imports; Zig accepts them (lazy analysis). If it ever objects,
  `Query.init(module, options)` is the free entry point.
- Non-exhaustive enums (`wasm.Opcode`, `MiscOpcode`, SIMD/atomics): `std.enums.fromInt` accepts any
  value; opcode tables are built from named fields only.
- `payload/types.zig` reads only `0x60` function types; the GC type forms (`0x4E/0x50/0x5E/0x5F`)
  are `UnsupportedFeature`, so a GC module's type section cannot be patched yet.
- Value types are one byte in the current reader/model. Prefixed reference forms
  (`0x63`/`0x64` + heap type) are refused with `UnsupportedFeature`. `EncodedValues` stores
  `value_count` explicitly and `fromOneByteEntryValues` names the current assumption; do not derive
  a value count from `bytes.len`. `docs/ARCHITECTURE.md` describes the future generalized form.
- The remapper runs at emit and resolves against `Plan.fromPatch`: only `add_imports`, `add_types`
  and `add_functions` contribute; a raw edit for one of those sections leaves the corresponding
  field empty, so the caller owns its indices.
- An added import is `.added_import = n` (the n-th import of its kind), not `.appended`: imports go
  before the module's own entities. An input import keeps its index; input defined entities and
  `.appended` entities shift by the added imports of their space; types never shift.
- Raw, kept and untouched bytes are never remapped: a `.raw` body, `Instr.raw`, `Expr.raw` or a
  copied span keeps the indices it was written with.
- Local bounds need `Body.Owner`: `SetBodies` builds it from `Plan`/`Query`, and a body on its own
  (`Body.encode`) has no owner and skips the check. `.raw`/`.keep` instruction bytes are never
  checked; `.keep`/`.append`/`.raw` locals vectors are parsed to count their locals. `Out` carries
  a precomputed `local_limit`, not the whole owner.
- `Where.function` is the final function index in the emitted module: input index + added function
  imports for a replacement, input function total + added imports + appended ordinal for a new body.
- `SetTables` names input **defined** tables by input index; imported tables are `ImportedTable`.
  The table section's count never changes, and its contents (the element section) are untouched.
  Raising a table's max does not allocate or initialize table slots.
- This Zig version: `@backingInt`/`@fromBackingInt`, `std.Io.Writer`, `w.writeLeb128`,
  `Io.Writer.Discarding.init(&.{})`.
- `&.{...}` needs a typed context. A plan that stores a slice needs storage that outlives it; arrays
  declared inside a function do not outlive the call, so name them in the caller's scope.
- Tests that emit modules check exact bytes, `outputLen` and section tiling; validate end-to-end
  modules with `wasm-validate` from `PATH`.
