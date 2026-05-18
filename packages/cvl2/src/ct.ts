// we're just reinventing comptemp

type Block = {
    offset: number,
    lines: BlockLine[],
    validate: symbol,
};
type BlockLine = {type: symbol, cfg: unknown, args: BlockArg[], ret: BlockType};
type BlockType = {type: symbol, cfg: unknown};
type BlockArg = {kind: "ref", index: number, type: BlockType, validate: symbol} | {kind: "comptime"};

type BlockLineT<T> = symbol & {__is_block_line: T};
type BlockTypeT<T> = symbol & {__is_block_type: T};
function blockLineSym<T>(): BlockLineT<NoInfer<T>> {
    return Symbol() as BlockLineT<T>;
}
function blockTypeSym<T>(): BlockTypeT<NoInfer<T>> {
    return Symbol() as BlockTypeT<T>;
}
function blockLine<K>(type: BlockLineT<K>, cfg: NoInfer<K>, args: BlockArg[], ret: BlockType): BlockLine {
    return {type, cfg, args, ret};
}
function blockType<K>(type: BlockTypeT<K>, cfg: NoInfer<K>): BlockType {
    return {type, cfg};
}
const convert_fail_sym = Symbol();
function registerTypeConversion<Src, Dst>(src: BlockTypeT<Src>, dst: BlockTypeT<Dst>, cb: (src: NoInfer<Src>) => NoInfer<Dst> | (typeof convert_fail_sym)): void {}
function registerLineConversion<Src, Dst>(src: BlockLineT<Src>, dst: BlockLineT<Dst>, cb: (src: NoInfer<Src>) => NoInfer<Dst>[] | (typeof convert_fail_sym)): void {}

const comptime = {
    Artifact: blockTypeSym<null>(),
    file_create: blockLineSym<null>(),
};
const basic = {
    void: blockTypeSym<null>(),
    noop: blockLineSym<null>(),
    int: blockTypeSym<{min: bigint, max: bigint}>(),
    add: blockLineSym<{lhs: BlockArg, rhs: BlockArg}>(),
};
const mc = {
    result: blockTypeSym<null>(),
    raw: blockLineSym<string>(),
};
const demo: Block = {
    offset: 0,
    lines: [
        blockLine(basic.noop, null, [], blockType(basic.void, null)),
    ],
    validate: Symbol(),
};

registerTypeConversion(basic.void, mc.result, (src) => {
    return null;
});
registerTypeConversion(basic.void, mc.result, (src) => {
    return null;
});
registerLineConversion(basic.noop, mc.raw, (src) => {
    return [];
});
registerTypeConversion(basic.int, mc.result, src => {
    if (src.min < -2,147,483,648) return convert_fail_sym;
    if (src.max > 2,147,483,647) return convert_fail_sym;
    return null;
});
registerLineConversion(basic.add, mc.raw, (src) => {
    return [
        "execute store result score $tmp qxc.tmp1 run <get.0>", // or really, get src.lhs -> $tmp qxc.tmp1
        "execute store result score $tmp qxc.tmp2 run <get.1>", // get src.rhs -> $tmp qxc.tmp2
        "scoreboard players operation $tmp qxc.tmp1 += $tmp qxc.tmp2",
    ];
});

// to convert, the reciever specifies which types are supported, and then we automatically convert
// ie we pathfind using the conversion weights from an unsupported type to a supported type
// we do need to figure out how to support eg i32 and i64 but not i33

// we want to be able to convert i128 to 2xi64, and then each of those to 2xi32 on a platform that supports i32 but not i128
// i128 example
// %0: i128 = int_init(123456789) <- this probably won't be a real instruction. maybe convert() can request conversion from comptime to initializers?
// %1: i128 = int_add(%0, $int(45))
// ->
// %0: struct(i64, i64) = blk{
//   %1: i64 = int_init(0)
//   %2: i64 = int_init(123456789)
//   -> pair_init(%1: i64, %2: i64)
// }
// %1: struct(i64, i64) = call($i128_add_64, %0, $pair_init(...))
//
// $i64_add::{...}
// note that all values are immutable, a reference needs to be like stack_alloc()
//
// or a simpler one, ranged ints to regular ints for c eg
// %0: int(0, 5) = ...
// %1: int(0, 10) = int_add(%0, %0)
// ->
// %0: int(0, 8) = ...
// %1: int(0, 16) = ...