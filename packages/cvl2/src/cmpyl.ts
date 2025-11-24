import { Adisp, comptimeEval } from "./cte";
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
        target: {kind: "comptime"},
    };
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
    target: TargetEnv,
};
export type TargetEnv = {
    kind: "comptime"
} | {
    kind: "todo",
};
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
export type ComptimeType = ComptimeTypeVoid | ComptimeTypeKey | ComptimeTypeAst | ComptimeTypeUnknown | ComptimeTypeType | ComptimeTypeNamespace | ComptimeTypeFn | ComptimeTypeFolderOrFile;

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

    return analyzeSub(env, slot, slot, pos, ast, ast.length - 1, block);
}

function analyzeSub(env: Env, slot: ComptimeType, rootSlot: ComptimeType, pos: TokenPosition, ast: SyntaxNode[], index: number, block: AnalysisBlock): AnalysisResult {
    const expr = ast[index]!;
    if (index === 0) {
        if (expr.kind === "raw" && expr.tag === "access") {
            const idx = blockAppend(block, {expr: "comptime:only", pos: expr.pos});
            return {idx, type: {
                type: "type",
                pos: slot.pos,
                narrow: rootSlot,
            }};
        }
        return analyzeBase(env, slot, expr, block);
    } else {
        const unknownSlot: ComptimeType = {type: "unknown", pos: compilerPos()};
        const lhs = analyzeSub(env, unknownSlot, rootSlot, pos, ast, index - 1, block);
        return analyzeSuffix(env, slot, lhs, expr, block);
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
    if (ast.kind === "builtin") {
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
    throwErr(env, ast.pos, "TODO analyzeBase: "+ast.kind+Adisp.dumpAst([ast], 3));
}
function analyzeSuffix(env: Env, slot: ComptimeType, result: AnalysisResult, ast: SyntaxNode, block: AnalysisBlock): AnalysisResult {
    if (ast.kind === "raw") {
        if (ast.tag === "access") return result; // todo
        throwErr(env, ast.pos, "unexpected raw: "+JSON.stringify(ast.raw));
    }
    if (ast.kind === "ident") {
        // access ident on result
        // the way to do this will vary based on the type
        return analyzeAccess(env, slot, result, ast.pos, {type: "string", key: ast.str}, block);
    }
    throwErr(env, ast.pos, "TODO analyzeSuffix: "+ast.kind);
}
function analyzeAccess(env: Env, slot: ComptimeType, obj: AnalysisResult, pos: TokenPosition, prop: ComptimeNarrowKey, block: AnalysisBlock): AnalysisResult {
    if (obj.type.type === "namespace") {
        if (!obj.type.narrow) throwErr(env, pos, "cannot access on non-narrowed namespace");
        if (prop.type === "string") {
            return obj.type.narrow.getString(env, pos, prop.key, block);
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
function readDestructure(env: Env, pos: TokenPosition, src: SyntaxNode[]): {str: string, pos: TokenPosition} {
    // TODO: support destructuring. ie:
    // a :: 25 ✓
    // [a, b] :: 25
    // [a :: .a, b :: .b] :: 25
    const lhsItems = trimWs(src);
    if (lhsItems.length < 1) throwErr(env, pos, "Expected ident for bind");
    const ident = lhsItems[0]!;
    if (ident.kind !== "ident") throwErr(env, ident.pos, `Expected ident for bind lhs, found ${ident.kind}`);
    if (lhsItems.length > 1) throwErr(env, lhsItems[1]!.pos, "Unexpected trailing item in bind lhs");
    return {str: ident.str, pos: ident.pos};
}
function readContainer(env: Env, pos: TokenPosition, src: SyntaxNode[]): ReadContainer {
    const lines: {items: SyntaxNode[], pos: TokenPosition}[] = readBinary(env, src, "sep") ?? [{items: src, pos: pos}];
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
                const ident = readDestructure(env, lhs.pos, lhs.items);
                const prev = res.bindings.get(ident.str);
                if (prev) {
                    // ideally we would prevent posting the error if the value is already an error
                    addErr(env, ident.pos, `Duplicate binding name ${ident.str}`, [
                        [prev.pos, "Previous definition here"],
                    ]);
                    res.bindings.set(ident.str, {pos: prev.pos, value: [{kind: "err", pos: prev.pos}]});
                } else {
                    res.bindings.set(ident.str, {pos: op.pos, value: rhs!.items});
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
function readBinary(env: Env, src: SyntaxNode[], kw: OpTag): OperatorSegmentToken[] | undefined {
    src = trimWs(src);
    if (src.length === 0) return undefined;
    if (src[0]!.kind !== "binary" || src[0]!.tag !== kw) return undefined;
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