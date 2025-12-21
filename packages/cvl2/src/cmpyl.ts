import { comptimeEval, getComptime } from "./cte";
import { prettyPrintErrors, renderTokenizedOutput, Source, tokenize, type BlockToken, type OperatorSegmentToken, type OperatorToken, type OpTag, type SyntaxNode, type TokenizationError, type TokenizationErrorEntry, type TokenizationErrorStyle, type TokenPosition, type TraceEntry } from "./cvl2";
import { isAbsolute, relative } from "path";
import { printers } from "./printers";

/*
todo: we may need to split up 'env' and 'scope'
*/

class PositionedError extends Error {
    e: TokenizationError;
    constructor(e: TokenizationError) {
        super([...e.entries.map(nt => `${nt.pos?.fyl ?? "???"}:${nt.pos?.lyn ?? "???"}:${nt.pos?.col ?? "???"}: ${nt.style}: ${nt.message}`), ...e.trace.map(t => ` at ${t.pos.fyl}:${t.pos.lyn}:${t.pos.col} (${t.text})`)].join("\n"));
        this.e = e;
    }
}
export class ConsumedError extends Error {}
function compilerPos(): TokenPosition {
    return {fyl: "compiler", lyn: 0, col: 0, idx: 0};
}
function emptyBlock(): AnalysisBlock {
    return {
        lines: [],
        validate: Symbol(),
    };
}

function importFile(filename: string, contents: string) {
    const sourceCode = new Source(filename, contents);
    const tokenized = tokenize(sourceCode);
    console.log(renderTokenizedOutput(tokenized, sourceCode));
    const rootPos: TokenPosition = {fyl: filename, lyn: 0, col: 0, idx: 0};
    
    const env: Env = {
        trace: [],
        errors: [...tokenized.errors],
        scope: {
            comptime: new Map(),
            bindings: new Map(),
        },
    };
    env.scope.comptime.set(target_env_symbol, {
        kind: "comptime",
    } satisfies TargetEnv);
    try {
        const block: AnalysisBlock = emptyBlock();
        const ns = analyzeNamespace(env, {fyl: filename, lyn: 0, col: 0, idx: 0}, tokenized.result);
        const mainFn = ns.getSymbol(env, rootPos, mainSymbolChildType, mainSymbolSymbol, block);
        if (!mainFn) throwErr(env, rootPos, "expected main fn");
        const callResult = analyzeCall(env, stdFolderOrFileType, rootPos, mainFn, {pos: compilerPos(), ast: [{kind: "raw", pos: compilerPos(), raw: "", tag: "void"}]}, block);
        const result = getComptime(env, "folder_or_file", comptimeEval(env, block, callResult.value, rootPos), rootPos);
        console.log("got result" + printers.folderOrFile.dump(result));
    }catch(err) {
        handleErr(env, err);
    }
    
    if (env.errors.length > 0) {
        console.log(prettyPrintErrors(sourceCode, env.errors));
        process.exit(1);
    }
}

export type Binding = {
    kind: "valid",
    pos: TokenPosition,
    decl: ComptimeValueDeclaration,
} | {
    kind: "error",
    pos: TokenPosition,
    consumed: ConsumedErrorToken,
} | {
    kind: "removed",
    pos: TokenPosition,
};
export type Scope = {
    comptime: Map<symbol, unknown>
    bindings: Map<string, Binding>,
};
export type Env = {
    trace: TraceEntry[],
    errors: TokenizationError[],
    scope: Scope,
};
export type TargetEnv = {
    kind: "comptime"
} | {
    kind: "todo",
};
const target_env_symbol = Symbol("target_env");
type ComptimeValueNamespace = {
    kind: "namespace",
    getString(env: Env, pos: TokenPosition, field: string, block: AnalysisBlock): AnalysisResult,
    getSymbol(env: Env, pos: TokenPosition, keychild: ComptimeType, field: symbol, block: AnalysisBlock): AnalysisResult | undefined,
    call?: BuiltinFn,
    pos: TokenPosition,
};

export type NsFields = {
    kind: "ns_fields",
    locked: boolean,
    registered: Map<string | symbol, {key: ComptimeValueKey, decl: ComptimeValueDeclaration}>,
};

function analyzeNamespace(rootEnv: Env, pos: TokenPosition, src: SyntaxNode[]): ComptimeValueNamespace {
    const block: AnalysisBlock = emptyBlock();
    const arrEntry = blockAppend(block, {expr: "comptime:ns_list_init", pos});
    const env = analyzeBlock(rootEnv, {type: "void", pos: compilerPos()}, pos, src, block, {
        analyzeBind(env, [lhs, op, rhs], block): AnalysisResult {
            const key = analyze(env, {type: "key", pos: compilerPos()}, lhs.pos, lhs.items, block);
            if (key.type.type !== "key") throw new Error("unreachable");
            if (key.value.kind !== "key") throwErr(env, lhs.pos, `Expected key, got ${key.value.kind}`, [
                [undefined, "This error is unnecessary because we're not varying the slot type of the value based on the type of the key"],
            ]);
            const value = analyze(env, {type: "ast", pos: compilerPos()}, rhs.pos, rhs.items, block);
            // insert an instruction to append the value to the children list
            // we could directly append here, but that would preclude `blk: [.a = 1, .b = 2, break :blk, .c = 3]` if we even want to support that
            const ret = blockAppend(block, {expr: "comptime:ns_list_append", pos: op.pos, list: arrEntry, key: key.value, value: value.value});
            return {type: {type: "void", pos: compilerPos()}, value: ret};
        },
    });
    const arrValue = getComptime(env, "ns_fields", comptimeEval(env, block, arrEntry, pos), pos);
    arrValue.locked = true;
    return {
        kind: "namespace",
        getString(accessEnv, pos, field, block) {
            const value = arrValue.registered.get(field);
            if (value) {
                throwErr(env, pos, "todo get registered field");
            }
            throwErr(env, pos, "string field '"+field+"' is not defined on namespace", [
                [pos, "namespace declared here"],
            ]);
        },
        getSymbol(accessEnv, pos, childt, field, outerBlock): AnalysisResult | undefined {
            const value = arrValue.registered.get(field);
            if (value) {
                const result = getDeclaration(env, value.decl);
                return result;
                // return {value: {kind: "optional", some: result.value}, type: {type: "optional", some: result.type}};
            }
            return undefined;
        },
        pos,
    };
}
type ComptimeValueDeclaration = {
    ast: ComptimeValueAst,
    valueCache: {match: Map<symbol, unknown>, result: AnalysisResult}[],
    _tmpValueCache?: "inprogress" | AnalysisResult,
};
export function createDeclaration(env: Env, ast: ComptimeValueAst): ComptimeValueDeclaration {
    return {ast, valueCache: []};
}
export function getDeclaration(env: Env, decl: ComptimeValueDeclaration): AnalysisResult {
    if (decl._tmpValueCache === "inprogress") throwErr(env, decl.ast.pos, "analysis cycle");
    if (decl._tmpValueCache) return decl._tmpValueCache;
    decl._tmpValueCache = "inprogress";
    const block: AnalysisBlock = emptyBlock();
    const result = analyze(decl.ast.env, {type: "unknown", pos: compilerPos()}, decl.ast.pos, decl.ast.ast, block);
    const evald = comptimeEval(decl.ast.env, block, result.value, decl.ast.pos);
    decl._tmpValueCache = {type: result.type, value: evald};
    return decl._tmpValueCache;
}
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
    const block: AnalysisBlock = emptyBlock();
    // set (type, ast) => (resolving)
    // set (type, ast) => (resolved type)
    // set (type, ast) => (resolved value)
    analyze(env, childt, value.ast.pos, value.ast.ast, block);
}
*/
function analyzeBlock(rootEnv: Env, slot: ComptimeType, pos: TokenPosition, src: SyntaxNode[], block: AnalysisBlock, cfg: {
    analyzeBind(env: Env, b2: Binary2, block: AnalysisBlock): AnalysisResult,
}): Env {
    const container = readContainer(rootEnv, pos, src);
    const env = container.env;
    
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

    return env;
}
export type ComptimeTypeVoid = {type: "void", pos: TokenPosition};
export type ComptimeTypeKey = {
    type: "key", pos: TokenPosition,
};
export type ComptimeTypeAst = {
    type: "ast", pos: TokenPosition,
};
export type ComptimeTypeUnknown = {
    type: "unknown", pos: TokenPosition,
};
export type ComptimeTypeType = {
    type: "type", pos: TokenPosition,
};
export type ComptimeTypeNamespace = {
    type: "namespace", pos: TokenPosition,
};
export type ComptimeTypeUint8Array = {
    type: "uint8array", pos: TokenPosition,
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
export type ComptimeTypeOptional = {
    type: "optional",
    pos: TokenPosition,
    some: ComptimeType,
};
export type ComptimeType = ComptimeTypeVoid | ComptimeTypeKey | ComptimeTypeAst | ComptimeTypeUnknown | ComptimeTypeType | ComptimeTypeNamespace | ComptimeTypeUint8Array | ComptimeTypeFn | ComptimeTypeFolderOrFile | ComptimeTypeTuple | ComptimeTypeOptional;

export type ComptimeValueKey = {
    kind: "key",
    type: "symbol",
    key: symbol,
    child: ComptimeType,
} | {
    kind: "key",
    type: "string",
    key: string,
};

export type ComptimeValueAst = {
    kind: "ast",
    ast: SyntaxNode[],
    pos: TokenPosition,
    env: Env,
    // TODO: some env stuff in here (ie scope)
};

// there may be a bunch of random instructions
// but not every backend will need to support every instruction
// backends will be able to define which instructions they support,
// and then other instructions will be transformed to the nearest supported instruction
// (it will assemble a plan for each unsupported instruction that uses the lowest cost list of
//  transforms to convert to a supported instruction)
export type AnalysisLine = {
    expr: "comptime:ns_list_init",
    pos: TokenPosition,
} | {
    expr: "comptime:ns_list_append",
    pos: TokenPosition,
    key: RuntimeValue,
    list: RuntimeValue,
    value: RuntimeValue,
} | {
    expr: "call",
    pos: TokenPosition,
    method: RuntimeValue,
    arg: RuntimeValue,
} | {
    expr: "break",
    pos: TokenPosition,
    // target: ...
    value: RuntimeValue,
} | {
    expr: "args",
    pos: TokenPosition,
} | {
    expr: "comptime:file_create",
    pos: TokenPosition,
    value: RuntimeValue,
};
export type AnalysisBlock = {
    lines: AnalysisLine[],
    validate: symbol,
};
export type AnalysisResult = {
    // TODO:
    // - remove narrow in types
    // - return the comptime value here if it is known, else the block idx
    type: ComptimeType,
    value: RuntimeValue,
};
type BlockIdx = number & {__is_block_idx: true};
function blockAppend(block: AnalysisBlock, instr: AnalysisLine): RuntimeValueRuntime {
    // TODO: if the instr has all comptime args, we may choose to evaluate at comptime instead
    block.lines.push(instr);
    return {kind: "runtime", idx: (block.lines.length - 1) as unknown as BlockIdx, validate: block.validate};
}
function castValue(to: ComptimeType, result: AnalysisResult): AnalysisResult {
    return {type: to, value: result.value};
}
function analyzeCall(env: Env, slot: ComptimeType, pos: TokenPosition, method: AnalysisResult, argIn: {pos: TokenPosition, ast: SyntaxNode[]}, block: AnalysisBlock): AnalysisResult {
    // alternatively: access property [call_symbol] on type
    if (method.type.type === "fn") {
        const arg = analyze(env, method.type.arg, argIn.pos, argIn.ast, block);
        return {
            value: blockAppend(block, {expr: "call", method: method.value, arg: arg.value, pos}),
            type: method.type.ret,
        };
    } else if (method.type.type === "type") {
        const slotType = getComptime(env, "type", method.value, pos);
        const result = analyze(env, slotType.type, argIn.pos, argIn.ast, block);
        return castValue(slotType.type, result);
    } else if (method.type.type === "namespace") {
        const val = getComptime(env, "namespace", method.value, pos);
        if (val.call == null) throwErr(env, pos, "this namespace does not support call", [
            [val.pos, "defined here"],
        ]);
        return val.call(env, slot, pos, argIn, block);
    } else throwErr(env, pos, "not supported call type: " + method.type.type);
}
function analyze(env: Env, slot: ComptimeType, pos: TokenPosition, ast: SyntaxNode[], block: AnalysisBlock): AnalysisResult {
    if (slot.type === "ast") {
        const value: ComptimeValueAst = {kind: "ast", ast: ast, env, pos};
        return {type: {
            type: "ast",
            pos: pos,
        }, value};
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
            lhs = {type: {
                type: "type",
                pos: slot.pos,
            }, value: {
                kind: "type",
                type: rootSlot,
            }};
        }
        const value: ComptimeValueKey = {kind: "key", type: "string", key: expr.str};
        return analyzeAccess(env, slot, lhs, expr.pos, {type: {
            type: "key",
            pos: expr.pos,
        }, value: value}, block);
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
        /*
            args,
            body: {kind: "ast", ast: expr.items, pos: expr.pos},
        */
        return {
            type: retTy,
            value: {
                kind: "fn",
                internal: {
                    args,
                    body: {kind: "ast", ast: expr.items, env, pos: expr.pos},
                    cachedBlock: null,
                },
                pos: expr.pos,
            },
        };
    } else if (expr.kind === "block" && expr.tag === "colon_call") {
        const unknownSlot: ComptimeType = {type: "unknown", pos: compilerPos()};
        const lhs = analyzeSub(env, unknownSlot, rootSlot, ast, index - 1, block);
        return analyzeCall(env, slot, expr.pos, lhs, {pos: expr.pos, ast: expr.items}, block);
    } else if (index === 0) {
        return analyzeBase(env, slot, expr, block);
    } else {
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
const mainSymbolValue: ComptimeValueKey = {
    kind: "key", type: "symbol", key: mainSymbolSymbol, child: mainSymbolChildType,
};
const mainSymbolType: ComptimeTypeKey = {
    type: "key",
    pos: compilerPos(),
};
type ComptimeValueVoid = {kind: "void"};
type ComptimeValueType = {
    kind: "type",
    type: ComptimeType,
};
type ComptimeValueFn = {
    kind: "fn",
    internal: {
        args: Destructure,
        body: ComptimeValueAst,
        cachedBlock: {block: AnalysisBlock, value: RuntimeValue} | "inprogress" | null,
    },
    pos: TokenPosition,
};
type BuiltinFn = (env: Env, slot: ComptimeType, pos: TokenPosition, arg: {pos: TokenPosition, ast: SyntaxNode[]}, block: AnalysisBlock) => AnalysisResult;
type ComptimeValueOptional = {
    kind: "optional",
    some?: ComptimeValue,
};
export type ComptimeValueFolderOrFile = {
    kind: "folder_or_file",
    value: Uint8Array | Record<string, ComptimeValueFolderOrFile>,
};
export type ComptimeValueUint8Array = {
    kind: "uint8array",
    value: Uint8Array,
};
export type ComptimeValue = ComptimeValueKey | ComptimeValueNamespace | ComptimeValueType | ComptimeValueAst | ComptimeValueVoid | NsFields | ComptimeValueFn | ComptimeValueOptional | ComptimeValueFolderOrFile | ComptimeValueUint8Array;
export type RuntimeValue = ComptimeValue | RuntimeValueRuntime;
export type RuntimeValueRuntime = {
    kind: "runtime",
    idx: BlockIdx,
    validate: symbol,
};
export function analyzeDestructure(env: Env, destructure: Destructure, value: RuntimeValue, block: AnalysisBlock): Env {
    if (destructure.extract.kind === "list") {
        for (let i = 0; i < destructure.extract.items.length; i++) {
            const item = destructure.extract.items[i]!;
            throwErr(env, item.pos, `TODO destructure list child ${i}:${printers.destructureExact.dump(item, 3)}`);
        }
        return env;
    } else throwErr(env, destructure.extract.pos, `TODO destructure block ${destructure.extract.kind}:${printers.destructure.dump(destructure, 3)}`)
}
export function compileFunction(rootEnv: Env, fn: ComptimeValueFn): {block: AnalysisBlock, value: RuntimeValue} {
    const env = fn.internal.body.env;
    if (fn.internal.cachedBlock === "inprogress") throwErr(env, fn.pos, "Compilation loop");
    if (fn.internal.cachedBlock) return fn.internal.cachedBlock;
    fn.internal.cachedBlock = "inprogress";
    const block = emptyBlock();
    const argsValue = blockAppend(block, {expr: "args", pos: fn.internal.args.extract.pos});
    const subEnv = analyzeDestructure(env, fn.internal.args, argsValue, block);
    const unknownSlot: ComptimeType = {type: "unknown", pos: compilerPos()};
    const result = analyze(subEnv, unknownSlot, fn.pos, fn.internal.body.ast, block);
    fn.internal.cachedBlock = {block, value: result.value};
    return fn.internal.cachedBlock;
}

abstract class Descriptor {
    _cache: AnalysisResult | null = null;
    abstract constructImpl(env: Env, route: string): AnalysisResult;
    construct(env: Env, route: string): AnalysisResult {
        // TODO: cache based on any referenced comptime env fields
        return this._cache ??= this.constructImpl(env, route);
    }
}
type NsDescOpts = {
    call?: BuiltinFn,
};
class NamespaceDescriptor extends Descriptor {
    pos: TokenPosition;
    constructor(public entries: Map<string, Descriptor | NsAccessorFn>, public opts: NsDescOpts) {
        super();
        const defloc = parseErrorStack(new Error()).filter(line => line.text !== "new NamespaceDescriptor" && line.text !== "ns" && line.text !== "throwErr");
        this.pos = defloc[0]?.pos ?? compilerPos();
    }
    constructImpl(env: Env, route: string): AnalysisResult {
        const results: Map<string, AnalysisResult> = new Map();
        for (const [key, value] of this.entries) {
            if (typeof value === "function") continue;
            results.set(key, value.construct(env, `${route}.${key}`));
        }
        return {type: {type: "namespace", pos: compilerPos()}, value: {
            kind: "namespace",
            getString: (env, pos, field, block): AnalysisResult => {
                const val = results.get(field);
                if (val) return val;
                const accessor = this.entries.get(field);
                if (typeof accessor === "function") return accessor(env, pos, block);
                throwErr(env, pos, `namespace ${route} does not have field: ${field}`);
            },
            getSymbol(env, pos, field, block): AnalysisResult | undefined {
                return undefined;
            },
            call: this.opts.call,
            pos: this.pos,
        }};
    }
}
class CustomDescriptor extends Descriptor {
    constructor(public cb: NsdFn | AnalysisResult) {super()}
    constructImpl(env: Env, route: string): AnalysisResult {
        if (typeof this.cb !== "function") return this.cb;
        return this.cb(env);
    }
}

type NsAccessorFn = (env: Env, pos: TokenPosition, block: AnalysisBlock) => AnalysisResult;
type NsdFn = (env: Env) => AnalysisResult;
const d = {
    raw(cb: NsdFn | AnalysisResult): CustomDescriptor {
        return new CustomDescriptor(cb);
    },
    ns(fields: Record<string, Descriptor | NsAccessorFn>, opts: NsDescOpts = {}): NamespaceDescriptor {
        return new NamespaceDescriptor(new Map(Object.entries(fields)), opts);
    },
};

const builtinNamespaceDescriptor = d.ns({
    main: d.raw({type: mainSymbolType, value: mainSymbolValue}),
    std: d.ns({
        File: d.raw({type: {type: "type", pos: compilerPos()}, value: {kind: "type", type: {type: "folder_or_file", pos: compilerPos()}}}),
        Folder: d.raw({type: {type: "type", pos: compilerPos()}, value: {kind: "type", type: {type: "folder_or_file", pos: compilerPos()}}}),
        c: d.ns({
            compile: d.ns({}, {call(env, slot, pos, arg, block) {
                throwErr(env, pos, "TODO call #builtin.std.c.compile");
            }}),
        }),
    }),
});

function analyzeBase(env: Env, slot: ComptimeType, ast: SyntaxNode, block: AnalysisBlock): AnalysisResult {
    if (ast.kind === "ident" && ast.identTag === "builtin") {
        if (ast.str === "builtin") {
            return builtinNamespaceDescriptor.construct(env, "#builtin");
        }else {
            throwErr(env, ast.pos, "unexpected builtin: #"+ast.str);
        }
    } else if (ast.kind === "ident" && ast.identTag === "normal") {
        const value = env.scope.bindings.get(ast.str);
        if (!value) throwErr(env, ast.pos, "not defined in scope: "+ast.str);
        if (value.kind === "error") throwConsumedErr(value.consumed);
        if (value.kind === "removed") throwErr(env, ast.pos, "not defined in scope: "+ast.str, [
            [value.pos, "removed here"],
        ]);
        return getDeclaration(env, value.decl);
    } else if (ast.kind === "block" && ast.tag === "string") {
        if (slot.type === "folder_or_file") {
            const str = analyzeBase(env, {type: "uint8array", pos: compilerPos()}, ast, block);
            const addedValue = blockAppend(block, {expr: "comptime:file_create", pos: ast.pos, value: str.value});
            return {type: {type: "folder_or_file", pos: compilerPos()}, value: addedValue};
        } else if (slot.type === "uint8array") {
            if (ast.items.length !== 1) throwErr(env, ast.pos, "TODO str items len != 1 todo" + printers.astNode.dumpList(ast.items, 3), [], "todo");
            const it0 = ast.items[0]!;
            if (it0.kind !== "strSeg") throwErr(env, ast.pos, "TODO str item 0 ! strSeg" + printers.astNode.dump(it0, 3));
            // if it has aggrandizements it might need runtime construction unless they're all comptime
            // although if it's a uint8array you can't runtime construct the aggrandizements so maybe it should just error
            return {type: {type: "uint8array", pos: compilerPos()}, value: {kind: "uint8array", value: enc.encode(it0.str)}};
        } else {
            throwErr(env, ast.pos, "TODO string in slot: " + printers.type.dump(slot, 3));
        }
    } else if (ast.kind === "raw" && ast.tag === "void") {
        return {type: {type: "void", pos: compilerPos()}, value: {kind: "void"}};
    } else {
        throwErr(env, ast.pos, "TODO analyzeBase: "+ast.kind+printers.astNode.dumpList([ast], 3));
    }
}
const enc = new TextEncoder();
function analyzeAccess(env: Env, slot: ComptimeType, obj: AnalysisResult, pos: TokenPosition, prop: AnalysisResult, block: AnalysisBlock): AnalysisResult {
    // TODO: this is only for comptime-known accesses but we should support runtime-known accesses
    if (obj.type.type === "namespace") {
        if (obj.value.kind !== "namespace") throwErr(env, pos, `cannot access on namespace type with value kind ${obj.value.kind}`);
        if (prop.type.type !== "key") throwErr(env, pos, "expected prop type key");
        if (prop.value.kind !== "key") throwErr(env, pos, "cannot access on namespace with non-narrowed prop value");
        if (prop.value.type === "string") {
            return obj.value.getString(env, pos, prop.value.key, block);
        }else{
            throwErr(env, pos, "TODO return ?symbolChildType .init(T) or .empty");
        }
    }
    throwErr(env, pos, "TODO: analyze access on type: "+obj.type.type);
}

// if we specialized our parser we wouldn't need to do this mess
// we could parse into
// brackets [ bindings = [key, value][], lines = [] ]

type ReadContainer = {
    env: Env,
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
    items: [ComptimeValueKey, DestructureExtract][],
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
function readContainer(rootEnv: Env, pos: TokenPosition, src: SyntaxNode[]): ReadContainer {
    const lines = readBinary(rootEnv, pos, src, "sep");
    const subscope: Scope = {
        ...rootEnv.scope,
        bindings: new Map(rootEnv.scope.bindings),
    }
    const res: ReadContainer = {
        env: {...rootEnv, scope: subscope},
        lines: [],
    };
    const env = res.env;
    for (const line of lines) {
        try {
            if (line.items.length === 0) continue;
            const rb2 = readBinary2(env, line.pos, line.items, "def");
            if (rb2) {
                // found binding
                const [lhs, op, rhs] = rb2;
                const destructure = readDestructure(env, lhs.pos, lhs.items);
                if (destructure.extract.kind !== "single_item") throwErr(env, destructure.extract.pos, "TODO: support destructure extract kind: " + destructure.extract.kind);
                const prev = subscope.bindings.get(destructure.extract.name);
                if (prev) {
                    // ideally we would prevent posting the error if the value is already an error
                    const tok = addErr(env, destructure.extract.pos, `Duplicate binding name ${destructure.extract.name}`, [
                        [prev.pos, "Previous definition here"],
                    ]);
                    subscope.bindings.set(destructure.extract.name, {pos: prev.pos, kind: "error", consumed: tok});
                } else {
                    
                    subscope.bindings.set(destructure.extract.name, {pos: op.pos, kind: "valid", decl: createDeclaration(env, {
                        kind: "ast",
                        ast: rhs!.items,
                        pos: rhs!.pos,
                        env,
                    })});
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
type Notes = [pos: TokenPosition | undefined, msg: string][];
export type ConsumedErrorToken = {__is_consumed_error: true};
export function throwConsumedErr(consumed: ConsumedErrorToken): never {
    // indicates the error has already been thrown and there is no purpose to throw it again
    throw new ConsumedError();
}
export function throwErr(env: Env | undefined, pos: TokenPosition | undefined, msg: string, notes?: Notes, style?: TokenizationErrorStyle): never {
    throw new PositionedError(getErr(env, pos, msg, notes, style))
}
export function addErr(env: Env, pos: TokenPosition | undefined, msg: string, notes?: Notes): ConsumedErrorToken {
    env.errors.push(getErr(env, pos, msg, notes));
    return {__is_consumed_error: true};
}
export function getErr(env: Env | undefined, pos: TokenPosition | undefined, msg: string, notes?: Notes, style: TokenizationErrorStyle = "error"): TokenizationError {
    const constructionLocation = parseErrorStack(new Error()).filter(line => line.text !== "getErr" && line.text !== "throwErr");
    return {
        entries: [
            {pos, style, message: msg},
            ...(notes ?? []).map((note): TokenizationErrorEntry => ({pos: note[0], style: "note", message: note[1]}))
        ],
        trace: [...env?.trace ?? [], ...constructionLocation],
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
export function assert(a: boolean, env?: Env, pos?: TokenPosition, msg?: string, notes?: Notes): asserts a {
    if (!a) throwErr(env, pos, msg ?? "no details provided", notes, "unreachable");
}

if(import.meta.main) {
    importFile("packages/cvl2/src/demo.qxc", await Bun.file(import.meta.dir + "/demo.qxc").text());
}