import { Adisp, comptimeEval, printers } from "./cte";
import { prettyPrintErrors, renderTokenizedOutput, Source, tokenize, type BlockToken, type OperatorSegmentToken, type OperatorToken, type OpTag, type SyntaxNode, type TokenizationError, type TokenizationErrorEntry, type TokenPosition, type TraceEntry } from "./cvl2";
import { isAbsolute, relative } from "path";

class PositionedError extends Error {
    e: TokenizationError;
    constructor(e: TokenizationError) {
        super([...e.entries.map(nt => `${nt.pos?.fyl ?? "???"}:${nt.pos?.lyn ?? "???"}:${nt.pos?.col ?? "???"}: ${nt.style}: ${nt.message}`), ...e.trace.map(t => ` at ${t.pos.fyl}:${t.pos.lyn}:${t.pos.col} (${t.text})`)].join("\n"));
        this.e = e;
    }
}
function compilerPos(): TokenPosition {
    return {fyl: "compiler", lyn: 0, col: 0, idx: 0};
}

function importFile(filename: string, contents: string) {
    const sourceCode = new Source(filename, contents);
    const tokenized = tokenize(sourceCode);
    console.log(renderTokenizedOutput(tokenized, sourceCode));
    const rootPos: TokenPosition = {fyl: filename, lyn: 0, col: 0, idx: 0};
    
    const env: Env = {
        trace: [],
        errors: [...tokenized.errors],
        comptime: new Map(),
    };
    env.comptime.set(target_env_symbol, {
        kind: "comptime",
    } satisfies TargetEnv);
    try {
        const block: AnalysisBlock = {
            lines: [],
        };
        const ns = analyzeNamespace(env, {fyl: filename, lyn: 0, col: 0, idx: 0}, tokenized.result);
        const mainFn = ns.getSymbol(env, rootPos, mainSymbolChildType, mainSymbolSymbol, block);
        if (!mainFn) throwErr(env, rootPos, "expected main fn");
        const callResult = analyzeCall(env, stdFolderOrFileType, rootPos, mainFn, (env, slot, pos, block) => ({idx: blockAppend(block, {expr: "void", pos: compilerPos()}), type: {type: "void", pos: compilerPos()}}), block);
        // blockAppend(block, {expr: "break", value: callResult.idx, pos: rootPos});
        comptimeEval(env, block);
    }catch(err) {
        handleErr(env, err);
    }
    
    if (env.errors.length > 0) {
        console.log(prettyPrintErrors(sourceCode, env.errors));
        process.exit(1);
    }
}

export type Env = {
    trace: TraceEntry[],
    errors: TokenizationError[],
    comptime: Map<symbol, unknown>,
};
export type TargetEnv = {
    kind: "comptime"
} | {
    kind: "todo",
};
const target_env_symbol = Symbol("target_env");
type ComptimeNamespace = {
    getString(env: Env, pos: TokenPosition, field: string, block: AnalysisBlock): AnalysisResult,
    getSymbol(env: Env, pos: TokenPosition, keychild: ComptimeType, field: symbol, block: AnalysisBlock): AnalysisResult | undefined,
};

export type NsFields = {
    locked: boolean,
    registered: Map<string | symbol, {key: ComptimeNarrowKey, ast: ComptimeValueAst}>,
};

function analyzeNamespace(env: Env, pos: TokenPosition, src: SyntaxNode[]): ComptimeNamespace {
    const block: AnalysisBlock = {
        lines: [],
    };
    const arrEntry = blockAppend(block, {expr: "comptime:ns_list_init", pos});
    let locked = false;
    analyzeBlock(env, {type: "void", pos: compilerPos()}, pos, src, block, {
        analyzeBind(env, [lhs, op, rhs], block): AnalysisResult {
            const key = analyze(env, {type: "key", pos: compilerPos()}, lhs.pos, lhs.items, block);
            if (key.type.type !== "key") throw new Error("unreachable");
            if (!key.type.narrow) throwErr(env, lhs.pos, "Expected narrowed key, got un-narrowed key", [
                [undefined, "This error is unnecessary because we're not varying the slot type of the value based on the type of the key"],
            ]);
            const value = analyze(env, {type: "ast", pos: compilerPos()}, rhs.pos, rhs.items, block);
            // insert an instruction to append the value to the children list
            // we could directly append here, but that would preclude `blk: [.a = 1, .b = 2, break :blk, .c = 3]` if we even want to support that
            const ret = blockAppend(block, {expr: "comptime:ns_list_append", pos: op.pos, list: arrEntry, key: key.idx, value: value.idx});
            return {type: {type: "void", pos: compilerPos()}, idx: ret};
        },
    });
    const results = comptimeEval(env, block);
    const arrValue = results[arrEntry] as NsFields;
    arrValue.locked = true;
    return {
        getString(env, pos, field, block) {
            const value = arrValue.registered.get(field);
            if (value) {
                throwErr(env, pos, "todo get registered field");
            }
            throwErr(env, pos, "string field '"+field+"' is not defined on namespace", [
                [pos, "namespace declared here"],
            ]);
        },
        getSymbol(env, pos, childt, field, outerBlock) {
            const value = arrValue.registered.get(field);
            if (value) {
                const block: AnalysisBlock = {lines: []};
                const result = analyze(env, childt, value.ast.pos, value.ast.ast, block);
                throwErr(env, pos, "todo handle analyzed result");
            }
            return undefined;
        },
    };
}
type ComptimeValueDeclaration = {
    ast: ComptimeValueAst,
    env: Env,
    valueCache: {match: Map<symbol, unknown>, result: unknown}[],
};
/*
function createDeclaration(env: Env, ast: ComptimeValueAst): ComptimeValueDeclaration {

}
function analyzeDeclaration(outerEnv: Env, ast: ComptimeValueAst): AnalysisResult {
    / *
    - first we check the cache to see if we have already analyzed the declaraion for our set of env values
    - no? analyze:
      - set analyzing=true
      - while analyzing, track which env values are used
      - when complete, store the mapping of (only referenced env values) -> (resolved)
      - we can also enable postType.
    - issues:
      - consider:
        ```
        a :: env(1) b
        b :: env == 1 ? env(0) b : 0

        analyze a (env=1)
        - analyze b (env=1)
          - analyze b (env=0) <- we're already analyzing!
      - we will need to just allow this and dependency loops are just like "stack overflow while analyzing x"
        ```
    * /
    const block: AnalysisBlock = {lines: []};
    // set (type, ast) => (resolving)
    // set (type, ast) => (resolved type)
    // set (type, ast) => (resolved value)
    analyze(env, childt, value.ast.pos, value.ast.ast, block);
}
*/
function analyzeBlock(env: Env, slot: ComptimeType, pos: TokenPosition, src: SyntaxNode[], block: AnalysisBlock, cfg: {
    analyzeBind(env: Env, b2: Binary2, block: AnalysisBlock): AnalysisResult,
}): AnalysisResult {
    const container = readContainer(env, pos, src);
    
    for (const line of container.lines) {
        // execute lines
        const rb2 = readBinary2(env, line.pos, line.items, "pub");
        if (rb2) {
            // have the caller analyze the bind
            cfg.analyzeBind(env, rb2, block);
        } else {
            // analyze the line
            analyze(env, {type: "void", pos: line.pos}, line.pos, line.items, block);
        }
    }


    const ret = blockAppend(block, {expr: "void", pos});
    return {idx: ret, type: {type: "void", pos: pos}};
}
export type ComptimeTypeVoid = {type: "void", pos: TokenPosition};
export type ComptimeTypeKey = {
    type: "key", pos: TokenPosition,
    narrow?: ComptimeNarrowKey,
};
export type ComptimeTypeAst = {
    type: "ast", pos: TokenPosition,
};
export type ComptimeTypeUnknown = {
    type: "unknown", pos: TokenPosition,
};
export type ComptimeTypeType = {
    type: "type", narrow?: ComptimeType, pos: TokenPosition,
};
export type ComptimeTypeNamespace = {
    type: "namespace", narrow?: ComptimeNamespace, pos: TokenPosition,
};
export type ComptimeTypeFn = {
    type: "fn",
    pos: TokenPosition,
    arg: ComptimeType,
    ret: ComptimeType,
};
export type ComptimeTypeFolderOrFile = {
    type: "folder_or_file",
    pos: TokenPosition,
};
export type ComptimeTypeTuple = {
    type: "tuple",
    pos: TokenPosition,
    children: ComptimeType[],
};
export type ComptimeType = ComptimeTypeVoid | ComptimeTypeKey | ComptimeTypeAst | ComptimeTypeUnknown | ComptimeTypeType | ComptimeTypeNamespace | ComptimeTypeFn | ComptimeTypeFolderOrFile | ComptimeTypeTuple;

export type ComptimeNarrowKey = {
    type: "symbol",
    key: symbol,
    child: ComptimeType,
} | {
    type: "string",
    key: string,
};

export type ComptimeValueAst = {
    ast: SyntaxNode[],
    pos: TokenPosition,
    // TODO: some env stuff in here (ie scope)
};

// there may be a bunch of random instructions
// but not every backend will need to support every instruction
// backends will be able to define which instructions they support,
// and then other instructions will be transformed to the nearest supported instruction
// (it will assemble a plan for each unsupported instruction that uses the lowest cost list of
//  transforms to convert to a supported instruction)
export type AnalysisLine = {
    expr: "comptime:only",
    pos: TokenPosition,
} | {
    expr: "comptime:ns_list_init",
    pos: TokenPosition,
} | {
    expr: "comptime:key",
    pos: TokenPosition,
    narrow: ComptimeNarrowKey,
} | {
    expr: "comptime:ast",
    pos: TokenPosition,
    narrow: ComptimeValueAst,
} | {
    expr: "comptime:ns_list_append",
    pos: TokenPosition,
    key: BlockIdx,
    list: BlockIdx,
    value: BlockIdx,
} | {
    expr: "void",
    pos: TokenPosition,
} | {
    expr: "call",
    pos: TokenPosition,
    method: BlockIdx,
    arg: BlockIdx,
} | {
    expr: "break",
    pos: TokenPosition,
    // target: ...
    value: BlockIdx,
};
export type AnalysisBlock = {
    lines: AnalysisLine[],
};
export type AnalysisResult = {
    // TODO:
    // - remove narrow in types
    // - return the comptime value here if it is known, else the block idx
    idx: BlockIdx,
    type: ComptimeType,
};
type BlockIdx = number & {__is_block_idx: true};
function blockAppend(block: AnalysisBlock, instr: AnalysisLine): BlockIdx {
    block.lines.push(instr);
    return block.lines.length - 1 as BlockIdx;
}
function analyzeCall(env: Env, slot: ComptimeType, pos: TokenPosition, method: AnalysisResult, getArg: (env: Env, slot: ComptimeType, pos: TokenPosition, block: AnalysisBlock) => AnalysisResult, block: AnalysisBlock): AnalysisResult {
    if (method.type.type === "fn") {
        const arg = getArg(env, method.type.arg, pos, block);
        return {
            idx: blockAppend(block, {expr: "call", method: method.idx, arg: arg.idx, pos}),
            type: method.type.ret,
        };
    } else throwErr(env, pos, "not supported call type: " + method.type.type);
}
function analyze(env: Env, slot: ComptimeType, pos: TokenPosition, ast: SyntaxNode[], block: AnalysisBlock): AnalysisResult {
    if (slot.type === "ast") {
        const value: ComptimeValueAst = {ast: ast, pos};
        const idx = blockAppend(block, {expr: "comptime:ast", pos, narrow: value});
        return {idx, type: {
            type: "ast",
            pos: pos,
        }};
    }
    ast = trimWs(ast);
    /*
    NEXT STEPS:
    - we need to analyze this:
      - block dot · packages/cvl2/src/demo.qxc:2:9
        - ident #"#builtin" · packages/cvl2/src/demo.qxc:2:1
      - ident main · packages/cvl2/src/demo.qxc:2:10
      - ws " " · packages/cvl2/src/demo.qxc:2:14
    // to analyze this:
    // we go left to right. right entries are on the left entries or something.
    // so first we analyze (block dot (ident #builtin))
    // then we take that result and analyze (ident main) on it
    */

    if (ast.length === 0) throwErr(env, pos, "failed to analyze empty expression");

    return analyzeSub(env, slot, slot, ast, ast.length - 1, block);
}

function analyzeSub(env: Env, slot: ComptimeType, rootSlot: ComptimeType, ast: SyntaxNode[], index: number, block: AnalysisBlock): AnalysisResult {
    const expr = ast[index]!;

    if (expr.kind === "ident" && expr.identTag === "access") {
        const unknownSlot: ComptimeType = {type: "unknown", pos: compilerPos()};
        let lhs: AnalysisResult;
        if (index >= 1) {
            lhs = analyzeSub(env, unknownSlot, rootSlot, ast, index - 1, block);
        } else {
            const idx = blockAppend(block, {expr: "comptime:only", pos: expr.pos});
            lhs = {idx, type: {
                type: "type",
                pos: slot.pos,
                narrow: rootSlot,
            }};
        }
        const narrow: ComptimeNarrowKey = {type: "string", key: expr.str};
        const idx = blockAppend(block, {expr: "comptime:key", pos: expr.pos, narrow});
        return analyzeAccess(env, slot, lhs, expr.pos, {idx, type: {
            type: "key",
            pos: expr.pos,
            narrow,
        }}, block);
    } else if (expr.kind === "block" && expr.tag === "arrow_fn") {
        let argSlotType: ComptimeType = {type: "unknown", pos: expr.pos};
        let retSlotType: ComptimeType = {type: "unknown", pos: expr.pos};
        if (slot.type === "fn") {
            argSlotType = slot.arg;
            retSlotType = slot.ret;
        }
        const args = readDestructure(env, expr.pos, ast.slice(0, index));
        console.log("destructure", printers.destructure.dump(args));
        const retTy: ComptimeTypeFn = {
            type: "fn",
            arg: args.type,
            ret: retSlotType,
            pos: expr.pos,
        };
        console.log("in slot", printers.type.dump(slot));
        console.log("result type", printers.type.dump(retTy));
        throwErr(env, expr.pos, "TODO: analyze the function now"); // we need to analyze the function to determine which runtime envs it depends on
        // this will require manual disambiguation for loops (like zig error sets).
        // const idx = blockAppend(block, {expr: "comptime:only", pos: expr.pos};
        // return {idx, type: retTy};
    }
    
    if (index === 0) {
        return analyzeBase(env, slot, expr, block);
    } else {
        // const unknownSlot: ComptimeType = {type: "unknown", pos: compilerPos()};
        // const lhs = analyzeSub(env, unknownSlot, rootSlot, ast, index - 1, block);
        // return analyzeSuffix(env, slot, lhs, expr, block);
        throwErr(env, expr.pos, "TODO analyzeSuffix: "+expr.kind+printers.astNode.dumpList([expr], 2));
    }
}

const stdFolderOrFileType: ComptimeTypeFolderOrFile = {type: "folder_or_file", pos: compilerPos()}; // type std.Folder | std.File
const mainSymbolSymbol = Symbol("main");
const mainSymbolChildType: ComptimeType = {
    type: "fn",
    arg: {type: "void", pos: compilerPos()},
    ret: stdFolderOrFileType,
    pos: compilerPos(),
};
const mainSymbolNarrow: ComptimeNarrowKey = {
    type: "symbol", key: mainSymbolSymbol, child: mainSymbolChildType,
};
const mainSymbolType: ComptimeTypeKey = {
    type: "key",
    pos: compilerPos(),
    narrow: mainSymbolNarrow,
};
function builtinNamespace(env: Env): ComptimeNamespace {
    return {
        getString(env, pos, field, block): AnalysisResult {
            if (field === "main") {
                const idx = blockAppend(block, {expr: "comptime:key", narrow: mainSymbolNarrow, pos});
                return {idx, type: mainSymbolType};
            } else {
                throwErr(env, pos, "builtin does not have field: "+field);
            }
        },
        getSymbol(env, pos, field, block): AnalysisResult | undefined {
            return undefined;
        },
    };
}
function analyzeBase(env: Env, slot: ComptimeType, ast: SyntaxNode, block: AnalysisBlock): AnalysisResult {
    if (ast.kind === "ident" && ast.identTag === "builtin") {
        if (ast.str === "builtin") {
            const idx = blockAppend(block, {expr: "comptime:only", pos: ast.pos});
            return {idx, type: {
                type: "namespace",
                narrow: builtinNamespace(env),
                pos: compilerPos(),
            }};
        }else {
            throwErr(env, ast.pos, "unexpected builtin: #"+ast.str);
        }
    }
    throwErr(env, ast.pos, "TODO analyzeBase: "+ast.kind+printers.astNode.dumpList([ast], 3));
}
function analyzeAccess(env: Env, slot: ComptimeType, obj: AnalysisResult, pos: TokenPosition, prop: AnalysisResult, block: AnalysisBlock): AnalysisResult {
    // TODO: this is only for comptime-known accesses but we should support runtime-known accesses
    if (obj.type.type === "namespace") {
        if (!obj.type.narrow) throwErr(env, pos, "cannot access on non-narrowed namespace");
        if (prop.type.type !== "key") throwErr(env, pos, "expected prop type key");
        if (!prop.type.narrow) throwErr(env, pos, "cannot access on namespace with non-narrowed prop value");
        if (prop.type.narrow.type === "string") {
            return obj.type.narrow.getString(env, pos, prop.type.narrow.key, block);
        }else{
            throwErr(env, pos, "TODO return ?symbolChildType .init(T) or .empty");
        }
    }
    throwErr(env, pos, "TODO: analyze access on type: "+obj.type.type);
}

// if we specialized our parser we wouldn't need to do this mess
// we could parse into
// brackets [ bindings = [key, value][], lines = [] ]

type ReadBinding = {
    pos: TokenPosition,
    value: SyntaxNode[],
};
type ReadContainer = {
    bindings: Map<string, ReadBinding>,
    lines: {items: SyntaxNode[], pos: TokenPosition}[],
};
export type Destructure = {
    extract: DestructureExtract,
    type: ComptimeType,
};
export type DestructureExtract = {
    kind: "single_item",
    name: string,
    pos: TokenPosition,
} | {
    kind: "list",
    items: DestructureExtract[],
    pos: TokenPosition,
} | {
    kind: "map",
    items: [ComptimeNarrowKey, DestructureExtract][],
    pos: TokenPosition,
};
function readDestructure(env: Env, pos: TokenPosition, src: SyntaxNode[]): Destructure {
    /*
    destructure types don't really make sense. here's the use-cases
    1. function args
            myfn :: (a: i32, b: i32) => i32: a + b
        here, the arg type is a new tuple (i32, i32)
    2. function args with some implicit
            ((i32, infer T) => i32): (a, b: i32) => a + b 
        the arg type should end up (i32, i32)
    3. function type args
            myfn_type: type :: (i32, i32) => i32
        zero clue what to do here. this one is a mess.
    4. destructuring 1
            (a: i32, b: i32) = (5, 6)
    5. destructuring 2
            (a: i32, b: i32) = (type: (i32, i32)): (5, 6)
        importantly, if destructure made a tuple here,
        it would not be equal to the type of the rhs which is problematic
    */
    const lhsItems = trimWs(src);
    if (lhsItems.length < 1) throwErr(env, pos, "Expected at least one item to destructure" + printers.astNode.dumpList(src, 2));
    if (lhsItems.length > 1) throwErr(env, lhsItems[1]!.pos, "Unexpected item for destructuring. TODO support eg 'name: type := value'" + printers.astNode.dumpList(src, 2));
    const ident = lhsItems[0]!;
    if (ident.kind === "ident" && ident.identTag === "normal") {
        if (lhsItems.length > 1) throwErr(env, lhsItems[1]!.pos, "Unexpected trailing item in destructure");
        return {
            extract: {kind: "single_item", name: ident.str, pos: ident.pos},
            type: {type: "unknown", pos: ident.pos},
        };
    } else if (ident.kind === "block" && ident.tag === "list") {
        const args = readBinary(env, ident.pos, ident.items, "sep");
        const extracts: DestructureExtract[] = [];
        const types: ComptimeType[] = [];
        for (const arg of args) {
            if (arg.items.length === 0) continue; // TODO: we should allow `[a\n\nb]` but disallow `[a,,b]`
            const sub = readDestructure(env, arg.pos, arg.items);
            extracts.push(sub.extract);
            types.push(sub.type);
        }
        return {
            extract: {kind: "list", items: extracts, pos: ident.pos},
            type: {type: "tuple", children: types, pos: ident.pos},
        };
        throwErr(env, ident.pos, "TODO: support destructing map kind");
    }
    throwErr(env, ident.pos, `Unsupported kind for destructuring: ${ident.kind}`);
}
function readContainer(env: Env, pos: TokenPosition, src: SyntaxNode[]): ReadContainer {
    const lines = readBinary(env, pos, src, "sep");
    const res: ReadContainer = {
        bindings: new Map(),
        lines: [],
    };
    for (const line of lines) {
        try {
            if (line.items.length === 0) continue;
            const rb2 = readBinary2(env, line.pos, line.items, "def");
            if (rb2) {
                // found binding
                const [lhs, op, rhs] = rb2;
                const destructure = readDestructure(env, lhs.pos, lhs.items);
                if (destructure.extract.kind !== "single_item") throwErr(env, destructure.extract.pos, "TODO: support destructure extract kind: " + destructure.extract.kind);
                const prev = res.bindings.get(destructure.extract.name);
                if (prev) {
                    // ideally we would prevent posting the error if the value is already an error
                    addErr(env, destructure.extract.pos, `Duplicate binding name ${destructure.extract.name}`, [
                        [prev.pos, "Previous definition here"],
                    ]);
                    res.bindings.set(destructure.extract.name, {pos: prev.pos, value: [{kind: "err", pos: prev.pos}]});
                } else {
                    res.bindings.set(destructure.extract.name, {pos: op.pos, value: rhs!.items});
                }
            } else {
                // found non-binding
                res.lines.push(line);
            }
        } catch (err) {
            handleErr(env, err);
        }
    }
    return res;
}
function trimWs(src: SyntaxNode[]): SyntaxNode[] {
    return src.filter(itm => itm.kind !== "ws");
}
type Binary2 = [OperatorSegmentToken, OperatorToken, OperatorSegmentToken];
function readBinary2(env: Env, pos: TokenPosition, rootSrc: SyntaxNode[], kw: OpTag): Binary2 | undefined {
    rootSrc = trimWs(rootSrc);
    if (rootSrc.length === 0) return undefined;
    if (rootSrc[0]!.kind !== "binary" || rootSrc[0]!.tag !== kw) return undefined;
    const src = trimWs(rootSrc[0]!.items);
    if (src.length !== 3) return throwErr(env, pos, "Expected LHS op RHS, found not that");
    const [lhs, op, rhs] = src;
    if (lhs?.kind !== "opSeg" || op?.kind !== "op" || rhs?.kind !== "opSeg") return undefined;
    return [lhs, op, rhs];
}
function readBinary(env: Env, pos: TokenPosition, src: SyntaxNode[], kw: OpTag): Omit<OperatorSegmentToken, "kind">[] {
    src = trimWs(src);
    if (src.length === 0) return [];
    if (src[0]!.kind !== "binary" || src[0]!.tag !== kw) {
        return [{items: src, pos}];
    }
    if (src.length > 1) throwErr(env, src[1]!.pos, "Found extra trailing items while parsing readBinary");
    return src[0]!.items.flatMap((itm): OperatorSegmentToken[] => {
        if (itm.kind === "opSeg") return [itm];
        if (itm.kind === "op") return [];
        throwErr(env, itm.pos, `Unexpected token in ${kw}: ${itm.kind}`);
    });
}
export function throwErr(env: Env, pos: TokenPosition | undefined, msg: string, notes?: [pos: TokenPosition | undefined, msg: string][]): never {
    throw new PositionedError(getErr(env, pos, msg, notes))
}
export function addErr(env: Env, pos: TokenPosition | undefined, msg: string, notes?: [pos: TokenPosition | undefined, msg: string][]): void {
    env.errors.push(getErr(env, pos, msg, notes))
}
export function getErr(env: Env, pos: TokenPosition | undefined, msg: string, notes?: [pos: TokenPosition | undefined, msg: string][]): TokenizationError {
    const constructionLocation = parseErrorStack(new Error()).filter(line => line.text !== "getErr" && line.text !== "throwErr");
    return {
        entries: [
            {pos: pos, style: "error", message: msg},
            ...(notes ?? []).map((note): TokenizationErrorEntry => ({pos: note[0], style: "note", message: note[1]}))
        ],
        trace: [...env.trace, ...constructionLocation],
    };
}
function parseErrorStack(error: Error): TraceEntry[] {
    const stack = error?.stack;
    if (!stack) return [];
    const matches = stack.matchAll(/^ {4}at (?:([^(\n]+) \(([^()\n]+?)(?::(\d+)(?::(\d+))?)?\)|([^()\n]+?)(?::(\d+)(?::(\d+))?)?)$/mg);
    const result: TraceEntry[] = [];
    for (const m of matches) {
        const filepath = m[2] ?? m[5] ?? "unknown";
        result.push({
            pos: {
                fyl: isAbsolute(filepath) ? relative(process.cwd(), filepath) : filepath,
                lyn: +(m[3] ?? m[6] ?? "-1"),
                col: +(m[4] ?? m[7] ?? "-1"),
                idx: -1,
            },
            text: m[1] ?? "unknown",
        });
    }
    return result;
}
function handleErr(env: Env, err: unknown): void {
    if (err instanceof PositionedError) {
        env.errors.push(err.e);
    }else{
        throw err;
    }
}
export function assert(a: boolean): asserts a {
    if (!a) throw new Error("assertion failed");
}

if(import.meta.main) {
    importFile("packages/cvl2/src/demo.qxc", await Bun.file(import.meta.dir + "/demo.qxc").text());
}