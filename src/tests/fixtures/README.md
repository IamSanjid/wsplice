# Fixtures

Committed binaries used by the tests. They are **never regenerated during
`zig build test`**: a different toolchain would change the bytes and break
the hand-verified expectations. Regenerate only on purpose, then redo the
checklist below.

## Files

| File | Source | Command | Purpose |
|---|---|---|---|
| minimal.wasm | minimal.wat | `wat2wasm --debug-names minimal.wat -o minimal.wasm` | hand-written; 7 sections + trailing `name` custom section |
| zig_basic.wasm | zig_basic.zig | `zig build-exe zig_basic.zig -target wasm32-freestanding -O ReleaseSmall -fno-entry -rdynamic` | real Zig output; table, element, data, custom sections |
| imports.wasm | imports.wat | `wat2wasm imports.wat -o imports.wasm` | function, table, memory and both global-mutability import descriptors; no tag import (needs exception-handling flags)

## Tool versions used

- zig: 0.18.0-dev.3227+9271780c4(`zig version`)
- wabt: 1.0.42(`wat2wasm --version`)

## After regenerating a fixture

1. `wasm-validate <file>.wasm` must pass.
2. `wasm-objdump -h <file>.wasm`, then paste the section table into the
   expectations in the tests (payload start/end per section, in file order).
3. Run `zig build test`, including `-Doptimize=safe`.
4. Update the tool versions above.
