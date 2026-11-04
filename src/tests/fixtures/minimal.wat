(module
  (type (func (param i32 i32) (result i32)))
  (func $add (type 0) (param i32 i32) (result i32)
    local.get 0
    local.get 1
    i32.add)
  (memory 1 2)
  (global $counter (mut i32) (i32.const 42))
  (export "add" (func $add))
  (export "memory" (memory 0))
  (export "counter" (global $counter))
  (data (i32.const 8) "hello"))