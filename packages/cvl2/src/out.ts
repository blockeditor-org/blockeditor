

function registerInstruction() {}
function registerType() {}
function registerConversion() {}

/*
%0: int[0...5] = value(1)
%1: int[0...5] = value(2)
%2: int[0...5] = add(%0, %1) ; add lhs and rhs, panic on overflow
-> %2
=>
%0: c:uint8_t = c:int_literal(1)
%1: c:uint8_t = c:int_literal(2)
%2: c:uint8_t = call(%add_catch_overflow_ptr, 0, 5, %0, %1)
-> %2


%0: *int[0..5] = alloc(int[0..5])
defer free(%0)
%1: void = set(%0, 1)
%2: void = set_add(%0, 2)
%3: int[0..5] = deref(%0)
-> %3
=>
%0: c:stack_ptr(c:uint8_t) = c:stack_alloc(c:uint8_t)
%1: c:ptr(c:uint8_t) = c:stack_to_ptr(%0)
%2: void = c:ptr_set(%1, 1)
%3: void = call(%add_catch_overflow_ptr, 0, 5, %1, 2)
%4: c:uint8_t = c:deref(%1)
-> %4
*/