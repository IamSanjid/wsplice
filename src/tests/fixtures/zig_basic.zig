fn double(x: i32) i32 {
    return x *% 2;
}
fn triple(x: i32) i32 {
    return x *% 3;
}
const handlers = [_]*const fn (i32) i32{ &double, &triple };

var counter: u32 = 0;

export const message: [5]u8 = "hello".*;

export fn add(a: i32, b: i32) i32 {
    return a +% b;
}

export fn apply(which: u32, x: i32) i32 {
    return handlers[which & 1](x); // indirect call: gives you a table + element section
}

export fn bump() u32 {
    counter += 1;
    return counter;
}
