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
    i32: blockTypeSym<null>(),
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
registerLineConversion(basic.add, mc.raw, (src) => {
    return [
        "execute store result score $tmp qxc.tmp1 run <get.0>", // or really, get src.lhs -> $tmp qxc.tmp1
        "execute store result score $tmp qxc.tmp2 run <get.1>", // get src.rhs -> $tmp qxc.tmp2
        "scoreboard players operation $tmp qxc.tmp1 += $tmp qxc.tmp2",
    ];
});
