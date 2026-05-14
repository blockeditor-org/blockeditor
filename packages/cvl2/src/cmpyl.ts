import { comptimeEval, getComptime } from "./cte";
import { prettyPrintErrors, renderTokenizedOutput, Source, tokenize, unescapeString, type BlockToken, type OperatorSegmentToken, type OperatorToken, type OpTag, type SyntaxNode, type TokenizationError, type TokenizationErrorEntry, type TokenizationErrorStyle, type TokenPosition, type TraceEntry } from "./cvl2";
import { isAbsolute, relative, sep } from "path";
import { readFileSync } from "fs";
import { Adisp, printers } from "./printers";
import { validateCName, type CValidatedIdentifierName } from "./backend/c";
import { codegenMcfunction, type ComptimeValueMc, type McCodegenCtx } from "./backend/mc";

/*
todo: we may need to split up 'env' and 'scope'
*/

type ComptimeEnvSets = [symbol, unknown][];
function allMatch(sets: ComptimeEnvSets, actual: Map<symbol, unknown>): boolean {
    for (const [key, value] of sets) {
        if (actual.get(key) !== value) {
            return false;
        }
    }
    return true;
}

export class PositionedError extends Error {
    e: TokenizationError;
    constructor(e: TokenizationError) {
        super([...e.entries.map(nt => `${nt.pos?.fyl ?? "???"}:${nt.pos?.lyn ?? "???"}:${nt.pos?.col ?? "???"}: ${nt.style}: ${nt.message}`), ...e.trace.map(t => ` at ${t.pos.fyl}:${t.pos.lyn}:${t.pos.col} (${t.text})`)].join("\n"));
        this.e = e;
    }
}
export class ConsumedError extends Error {}
export function compilerPos(): TokenPosition {
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
            comptime: new ComptimeScopeMap(undefined, new Map([
                [target_env_symbol, {
                    kind: "build",
                } satisfies TargetEnv],
            ])),
            bindings: new Map(),
        },
        fnCache: new PerComptimeScopeCache(),
        declCache: new PerComptimeScopeCache(),
        builtinCache: new PerComptimeScopeCache(),
    };
    try {
        const block: AnalysisBlock = emptyBlock();
        const ns = analyzeNamespace(env, {fyl: filename, lyn: 0, col: 0, idx: 0}, tokenized.result);
        const mainFn = ns.getSymbol(env, rootPos, buildSymbolChildType, buildSymbolSymbol, block);
        if (!mainFn) throwErr(env, rootPos, "expected main fn");
        const callResult = analyzeCall(env, stdFolderOrFileType, rootPos, mainFn, {pos: compilerPos(), ast: [{kind: "raw", pos: compilerPos(), raw: "", tag: "void"}]}, block);
        const result = getComptime(env, "build_artifact", comptimeEval(env, block, callResult.value, rootPos), rootPos);
        console.log("got result" + printers.folderOrFile.dump(result));
    }catch(err) {
        handleErr(env, err);
    }
    
    if (env.errors.length > 0) {
        console.log(prettyPrintErrors([
            sourceCode,
            new Source("src" + sep + "cmpyl.ts", readFileSync(__filename, "utf-8")),
        ], env.errors));
        process.exit(1);
    }
}

export type Binding = {
    kind: "valid",
    pos: TokenPosition,
    decl: ComptimeValueDeclaration,
} | {
    kind: "runtime",
    pos: TokenPosition,
    runtime: AnalysisResult,
} | {
    kind: "error",
    pos: TokenPosition,
    consumed: ConsumedErrorToken,
} | {
    kind: "removed",
    pos: TokenPosition,
};
export class ComptimeScopeMap {
    parent?: ComptimeScopeMap;
    #changes: Map<symbol, unknown>;
    closed: boolean;
    #track?: Set<symbol>;
    constructor(parent: ComptimeScopeMap | undefined, changes: Map<symbol, unknown>, track: boolean = false) {
        this.parent = parent;
        this.#changes = changes;
        this.closed = false;
        if (track) this.#track = new Set();
    }
    get(key: symbol): unknown | undefined {
        if (this.#track) {
            if (this.closed && !this.#track.has(key)) throw new Error("uh oh! tried to introduce new tracked symbol after closing the track");
            this.#track.add(key);
        }
        return this.getUntrack(key);
    }
    getUntrack(key: symbol): unknown | undefined {
        if (this.#changes.has(key)) return this.#changes.get(key);
        return this.parent?.get(key);
    }
    sub(changes: Map<symbol, unknown>): ComptimeScopeMap {
        return new ComptimeScopeMap(this, new Map(changes));
    }
    subTrackAccesses(): ComptimeScopeMap {
        return new ComptimeScopeMap(this, new Map(), true);
    }
    endTrackAccesses(): symbol[] {
        if (!this.#track) throw new Error("unreachable");
        this.closed = true;
        return [...this.#track];
    }
}
export type Scope = {
    comptime: ComptimeScopeMap,
    bindings: Map<string, Binding>,
};
export type Env = {
    trace: TraceEntry[],
    errors: TokenizationError[],
    scope: Scope,
    fnCache: PerComptimeScopeCache<ComptimeValueFn, AnalyzedFn>,
    declCache: PerComptimeScopeCache<ComptimeValueDeclaration, ComptimeAnalysisResult>,
    builtinCache: PerComptimeScopeCache<Descriptor, AnalysisResult>,
};
export type AnalyzedFn = {block: AnalysisBlock, value: RuntimeValue};
export class PerComptimeScopeCache<T extends {}, U> {
    #entries = new WeakMap<T, {matches: {key: symbol, value: unknown}[], value: U}[]>();
    #depLoop = new WeakSet<T>();
    constructor() {}
    // TODO
    getOrPut(key: T, env: Env, cb: (env: Env) => U): U {
        if (this.#entries.has(key)) {
            // find matches
            const entry = this.#entries.get(key)!;
            for (const option of entry) {
                let blk = true;
                for (const match of option.matches) {
                    if (env.scope.comptime.getUntrack(match.key) !== match.value) {
                        blk = false;
                        break;
                    }
                }
                if (!blk) continue;

                // matches! (there should be only one matching value)
                return option.value;
            }
        }
        if (this.#depLoop.has(key)) {
            // TODO: we may want to allow dependency loops in some cases
            // ie if the outer one has already accessed a comptime env value that has changed in the inner one, so they can't possibly be a match
            // that will allow you to make an infinite loop by:
            //    myenv :: comptime_env: i32
            //    demo :: myenv.with(myenv.get() + 1, || demo)
            // because it will just keep reanalyzing demo over and over again with incrementing values of myenv
            // but that's probably fine? 
            throwErr(env, compilerPos(), "dependency loop"); // TODO positions
        }

        // 1. mark dependency loop
        this.#depLoop.add(key);
        // 2. begin tracking comptime scope dependencies
        const trackingComptime = env.scope.comptime.subTrackAccesses();
        // 3. eval cb
        const res = cb({
            ...env,
            scope: {
                ...env.scope,
                comptime: trackingComptime,
            },
        });
        // 4. end tracking comptime scope dependencies
        const dependencies = trackingComptime.endTrackAccesses();
        // 5. unmark dependency loop
        this.#depLoop.delete(key);
        // 5. save result
        if (!this.#entries.has(key)) this.#entries.set(key, []);
        this.#entries.get(key)!.push({
            matches: dependencies.map(dep => ({key: dep, value: env.scope.comptime.getUntrack(dep)})),
            value: res,
        });
        return res;
    }
}
export type TargetEnv = {
    kind: "build"
} | {
    kind: "c"
} | {
    kind: "mc"
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
    kind: "comptime:kv_fields",
    locked: boolean,
    entries: {pos: TokenPosition, key: ComptimeValue, value: ComptimeValue}[],
};

function analyzeNamespace(rootEnv: Env, pos: TokenPosition, src: SyntaxNode[]): ComptimeValueNamespace {
    const block: AnalysisBlock = emptyBlock();
    const arrEntry = blockAppend(block, {expr: "comptime:kv_list_init", pos});
    const {env} = analyzeBlock(rootEnv, {type: "void", pos: compilerPos()}, pos, src, block, {
        analyzeBind(env, [lhs, op, rhs], block): AnalysisResult {
            const key = analyze(env, {type: "key", pos: compilerPos()}, lhs.pos, lhs.items, block);
            if (key.type.type !== "key") throw new Error("unreachable");
            if (key.value.kind !== "key") throwErr(env, lhs.pos, `Expected key, got ${key.value.kind}`, [
                [undefined, "This error is unnecessary because we're not varying the slot type of the value based on the type of the key"],
            ]);
            const value = analyze(env, {type: "ast", pos: compilerPos()}, rhs.pos, rhs.items, block);
            // insert an instruction to append the value to the children list
            // we could directly append here, but that would preclude `blk: [.a = 1, .b = 2, break :blk, .c = 3]` if we even want to support that
            const ret = blockAppend(block, {expr: "comptime:kv_list_append", pos: op.pos, list: arrEntry, key: key.value, value: value.value});
            return {type: {type: "void", pos: compilerPos()}, value: ret};
        },
    });
    const arrValue = getComptime(env, "comptime:kv_fields", comptimeEval(env, block, arrEntry, pos), pos);
    arrValue.locked = true;

    const registered = new Map<string | symbol, {kind: "ok", decl: ComptimeValueDeclaration, pos: TokenPosition} | {kind: "error", etok: ConsumedErrorToken, pos: TokenPosition}>();
    for (const entry of arrValue.entries) {
        const key = getComptime(env, "key", entry.key, entry.pos);
        const value = getComptime(env, "ast", entry.value, entry.pos);
        if (registered.has(key.key)) {
            const prevdef = registered.get(key.key)!;
            const etok = addErr(env, entry.pos, "duplicate definition", [
                [prevdef.pos, "previous definition here"],
            ]);
            registered.set(key.key, {kind: "error", etok, pos: prevdef.pos});
            continue;
        }
        registered.set(key.key, {kind: "ok", decl: createDeclaration(env, value), pos: entry.pos});
    }

    return {
        kind: "namespace",
        getString(accessEnv, pos, field, block) {
            const value = registered.get(field);
            if (value) {
                throwErr(env, pos, "todo get registered field");
            }
            throwErr(env, pos, "string field '"+field+"' is not defined on namespace", [
                [pos, "namespace declared here"],
            ]);
        },
        getSymbol(accessEnv, pos, childt, field, outerBlock): AnalysisResult | undefined {
            const value = registered.get(field);
            if (value) {
                if (value.kind === "error") throwConsumedErr(value.etok);
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
};
export function createDeclaration(env: Env, ast: ComptimeValueAst): ComptimeValueDeclaration {
    return {ast};
}
export function getDeclaration(env: Env, decl: ComptimeValueDeclaration): ComptimeAnalysisResult {
    return env.declCache.getOrPut(decl, env, (env: Env): ComptimeAnalysisResult => {
        const block: AnalysisBlock = emptyBlock();
        const result = analyze(decl.ast.env, {type: "unknown", pos: compilerPos()}, decl.ast.pos, decl.ast.ast, block);
        const evald = comptimeEval(decl.ast.env, block, result.value, decl.ast.pos);
        return {type: result.type, value: evald};
    });
}
type AnalyzedBlock = {env: Env, result: AnalysisResult};
function analyzeBlock(rootEnv: Env, slot: ComptimeType, pos: TokenPosition, src: SyntaxNode[], block: AnalysisBlock, cfg: {
    analyzeBind(env: Env, b2: Binary2, block: AnalysisBlock): AnalysisResult,
}): AnalyzedBlock {
    const container = readContainer(rootEnv, pos, src);
    let env = container.env;
    
    let ret: AnalysisResult | undefined;
    let retloc: TokenPosition | undefined;
    for (const line of container.lines) {
        if (ret) {
            const etok = addErr(env, line.pos, "extra lines not allowed after return", [
                ...retloc ? [[retloc, "returned here"] satisfies [TokenPosition, string]] : [],
            ]);
            // not sure what to do with the error token
            // (perhaps return an error analysis result?)
            break;
        }
        // execute lines
        const rb2 = readBinary2(env, line.items, "pub");
        if (rb2) {
            // have the caller analyze the bind
            cfg.analyzeBind(env, rb2, block);
        } else {
            const rb3 = readBinary2(env, line.items, "var");
            if (rb3) {
                const [lhs, op, rhs] = rb3;
                const destructure = readDestructure(env, lhs.pos, lhs.items);
                const rhsanalyzed = analyze(env, destructure.type, rhs.pos, rhs.items, block);
                const destructured = analyzeDestructure(env, destructure, rhsanalyzed, block);
                const newBindings = new Map(env.scope.bindings);
                for (let i = 0; i < destructure.targets.length; i++) {
                    const target = destructure.targets[i]!;
                    const value = destructured[i]!;
                    newBindings.set(target.name, {kind: "runtime", pos: target.pos, runtime: value});
                }
                env = {...env, scope: {...env.scope, bindings: newBindings}};
            } else {
                // analyze the line
                // TODO: if '->', use the specified slot. else, use void.
                const trimmed = trimWs(line.items); // oops this is duplicated in analyze() too
                if (trimmed[0]?.kind === "raw" && trimmed[0].tag === "return") {
                    retloc = trimmed[0].pos;
                    ret = analyze(env, slot, line.pos, trimmed.slice(1), block);
                } else {
                    analyze(env, {type: "void", pos: line.pos}, line.pos, line.items, block);
                }
            }
        }
    }

    if (ret) return {env, result: ret};
    return {env, result: {type: {type: "void", pos: pos}, value: {kind: "void"}}};
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
export type ComptimeTypeBuildResult = {
    type: "build_artifact",
    narrow?: "folder" | "file",
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
export type ComptimeTypeExportList = {
    type: "export_list",
    key: ComptimeType,
    pos: TokenPosition,
};
export type ComptimeTypeCExportName = {
    type: "c:export_name",
    pos: TokenPosition,
};
export type ComptimeTypeMcIdentifier = {
    type: "mc:identifier",
    category?: string,
    pos: TokenPosition,
};
export type ComptimeTypeMcResult = {
    type: "mc:result",
    narrow?: "i32" | "error",
    pos: TokenPosition,
};
export type ComptimeTypeMcNbt = {
    type: "mc:nbt_ref",
    narrow?: "string" | "i8" | "i16" | "i32" | "i64" | "f32" | "f64" | [ComptimeTypeMcNbt] | Map<string, ComptimeTypeMcNbt>,
    pos: TokenPosition,
};
export type ComptimeType = ComptimeTypeVoid | ComptimeTypeKey | ComptimeTypeAst | ComptimeTypeUnknown | ComptimeTypeType | ComptimeTypeNamespace | ComptimeTypeUint8Array | ComptimeTypeFn | ComptimeTypeBuildResult | ComptimeTypeTuple | ComptimeTypeOptional | ComptimeTypeExportList | ComptimeTypeMcIdentifier | ComptimeTypeCExportName | ComptimeTypeMcResult | ComptimeTypeMcNbt;

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
    expr: "comptime:kv_list_init",
    pos: TokenPosition,
} | {
    expr: "comptime:kv_list_append",
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
} | {
    expr: "mc:exec_raw",
    pos: TokenPosition,
    command: RuntimeValue,
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
export type ComptimeAnalysisResult = {
    type: ComptimeType,
    value: ComptimeValue,
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
    if (ast[0]?.kind === "raw" && ast[0].tag === "return") throwErr(env, ast[0].pos, "can't return here");

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
        // TODO: we need to infer the ret type of the function?
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

const stdFolderOrFileType: ComptimeTypeBuildResult = {type: "build_artifact", pos: compilerPos()}; // type std.Folder | std.File
const buildSymbolSymbol = Symbol("build");
const buildSymbolChildType: ComptimeType = {
    type: "fn",
    arg: {type: "void", pos: compilerPos()},
    ret: stdFolderOrFileType,
    pos: compilerPos(),
};
const buildSymbolValue: ComptimeValueKey = {
    kind: "key", type: "symbol", key: buildSymbolSymbol, child: buildSymbolChildType,
};
const buildSymbolType: ComptimeTypeKey = {
    type: "key",
    pos: compilerPos(),
};
type ComptimeValueVoid = {kind: "void"};
type ComptimeValueType = {
    kind: "type",
    type: ComptimeType,
};
export type ComptimeValueFn = {
    kind: "fn",
    internal: {
        args: Destructure,
        body: ComptimeValueAst,
    },
    pos: TokenPosition,
};
type BuiltinFn = (env: Env, slot: ComptimeType, pos: TokenPosition, arg: {pos: TokenPosition, ast: SyntaxNode[]}, block: AnalysisBlock) => AnalysisResult;
type ComptimeValueOptional = {
    kind: "optional",
    some?: ComptimeValue,
};
export type ComptimeValueBuildArtifact = {
    kind: "build_artifact",
    value: ComptimeFolder | ComptimeFile,
};
export type ComptimeFolder = {
    kind: "folder",
    value: Map<string, ComptimeValueBuildArtifact>,
};
export type ComptimeFile = {
    kind: "file",
    value: Uint8Array,
};
export type ComptimeValueUint8Array = {
    kind: "uint8array",
    value: Uint8Array,
    sourcemap: Uint8ArraySourcemapEntry[],
};
export type Uint8ArraySourcemapEntry = {
    lenBytes: number,
    startPos: TokenPosition,
};
export type ComptimeValueCExportName = {
    kind: "c:export_name",
    value: CValidatedIdentifierName,
};
export type ComptimeValueMcIdentifier = {
    kind: "mc:identifier",
    namespace: string,
    path: string,
};
export type ComptimeValueExportList = {
    kind: "export_list",
    exports: {key: ComptimeValue, keyPos: TokenPosition, value: ComptimeValueAst}[],
};
export type ComptimeValueError = {
    kind: "error",
    etok: ConsumedErrorToken,
};
export type ComptimeValue = ComptimeValueKey | ComptimeValueNamespace | ComptimeValueType | ComptimeValueAst | ComptimeValueVoid | NsFields | ComptimeValueFn | ComptimeValueOptional | ComptimeValueBuildArtifact | ComptimeValueUint8Array | ComptimeValueExportList | ComptimeValueCExportName | ComptimeValueMcIdentifier | ComptimeValueError | ComptimeValueMc;
export type RuntimeValue = ComptimeValue | RuntimeValueRuntime;
export type RuntimeValueRuntime = {
    kind: "runtime",
    idx: BlockIdx,
    validate: symbol,
};
export function analyzeFunction(outerEnv: Env, fn: ComptimeValueFn): AnalyzedFn {
    // TODO: what we need to do is track which env.scope.comptime values the body accesses
    // and then only recompile if any of those items change
    const env: Env = {
        ...outerEnv,
        scope: {
            comptime: outerEnv.scope.comptime,
            bindings: fn.internal.body.env.scope.bindings,
        },
    };
    return env.fnCache.getOrPut(fn, env, env => {
        const block = emptyBlock();
        const argsValue = blockAppend(block, {expr: "args", pos: fn.internal.args.extract.pos});
        const subEnv = env;
        const unknownSlot: ComptimeType = {type: "unknown", pos: compilerPos()};
        const result = analyze(subEnv, unknownSlot, fn.pos, fn.internal.body.ast, block);
        return {block, value: result.value};
    });
}

abstract class Descriptor {
    _cache: AnalysisResult | null = null;
    abstract constructImpl(env: Env, route: string): AnalysisResult;
    construct(env: Env, route: string): AnalysisResult {
        return env.builtinCache.getOrPut(this, env, env => this.constructImpl(env, route));
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
                throwErr(env, pos, `namespace ${route} does not have field: ${field}`, [
                    [this.pos, "namespace defined here"],
                ]);
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
    build: d.raw({type: buildSymbolType, value: buildSymbolValue}),
    std: d.ns({
        File: d.raw({type: {type: "type", pos: compilerPos()}, value: {kind: "type", type: {type: "build_artifact", narrow: "file", pos: compilerPos()}}}),
        Folder: d.raw({type: {type: "type", pos: compilerPos()}, value: {kind: "type", type: {type: "build_artifact", narrow: "file", pos: compilerPos()}}}),
        mc: d.ns({
            runCommand: d.ns({}, {call(env, slot, pos, argAst, block): AnalysisResult {
                // TODO we should accept three args:
                // entity(mc:selector), position(mc:position), command nbt
                const arg = analyze(env, {type: "mc:nbt_ref", narrow: "string", pos}, argAst.pos, argAst.ast, block);
                const res = blockAppend(block, {expr: "mc:exec_raw", pos, command: arg.value});
                return {type: {type: "mc:result", pos}, value: res};
            }}),
            Result: d.raw({type: {type: "type", pos: compilerPos()}, value: {kind: "type", type: {type: "mc:result", pos: compilerPos()}}}),
            Datapack: d.ns({
                compile: d.ns({}, {call(envIn, slot, pos, argAst, block): AnalysisResult {
                    const env = {...envIn, scope: {
                        ...envIn.scope,
                        comptime: envIn.scope.comptime.sub(new Map([
                            [target_env_symbol, {
                                kind: "mc",
                            } satisfies TargetEnv],
                        ])),
                    }};
                    const argRes = analyze(env, {type: "export_list", key: {type: "mc:identifier", pos}, pos}, argAst.pos, argAst.ast, block);
                    const argCt = getComptime(env, "export_list", argRes.value, pos);
                    const resFiles = new Map<string, Uint8Array>();

                    const ctx: McCodegenCtx = {
                        fns: new Map(),
                        gid: 0,
                        internalNs: "_0",
                    };
                    
                    for (const item of argCt.exports) {
                        const ident = getComptime(env, "mc:identifier", item.key, pos);
                        const body = analyze(env, {type: "unknown", pos: compilerPos()}, item.value.pos, item.value.ast, block);
                        if (body.type.type === "fn") {
                            const content = getComptime(env, "fn", body.value, item.value.pos);
                            if (ctx.fns.has(content)) throwErr(env, pos, "duplicate item");
                            ctx.fns.set(content, ident);
                        } else throwErr(env, pos, "TODO mc body type: " + printers.runtimeValue.dumpList([item.key, item.value]));
                    }
                    for (const [content, ident] of ctx.fns.entries()) {
                        const compiled = analyzeFunction(env, content);
                        // now we need to compile & emit the mcfunction
                        const result = codegenMcfunction(env, ctx, compiled.block, compiled.value);
                        resFiles.set(`data/${ident.namespace}/functions/${ident.path}.mcfunction`, enc.encode(result));
                    }
                    return {type: {type: "build_artifact", pos, narrow: "folder"}, value: {kind: "build_artifact", value: {
                        kind: "folder",
                        value: new Map([...resFiles.entries()].map(([k, v]): [string, ComptimeValueBuildArtifact] => ([
                            k,
                            {kind: "build_artifact", value: {kind: "file", value: v}},
                        ]))),
                    }}};
                }}),
            }),
        }),
        c: d.ns({
            compile: d.ns({}, {call(envIn, slot, pos, argAst, block) {
                // now what we need to do is update the scope to set the compile target to c,
                const env = {
                    ...envIn,
                    scope: {
                        ...envIn.scope,
                        comptime: envIn.scope.comptime.sub(new Map([
                            [target_env_symbol, {
                                kind: "c",
                            } satisfies TargetEnv],
                        ])),
                    },
                };
                const argRes = analyze(env, {type: "export_list", key: {type: "c:export_name", pos}, pos}, argAst.pos, argAst.ast, block);
                const argCt = getComptime(env, "export_list", argRes.value, pos);
                for (const {key, keyPos: key_pos, value} of argCt.exports) {
                    const kv = getComptime(env, "c:export_name", key, key_pos);
                }
                // then readContainer the arg,
                //   - arguably shouldn't be readContainer, instead we should analyze it as a type 'export_list'
                // then analyze all the entries and emit???
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
        if (value.kind === "valid") return getDeclaration(env, value.decl);
        if (value.kind === "runtime") {
            if (value.runtime.value.kind === "runtime" && value.runtime.value.validate !== block.validate) throwErr(env, ast.pos, "not accessible");
            return value.runtime;
        }
        throwErr(env, ast.pos, "unreachable?");
    } else if (ast.kind === "block" && ast.tag === "string") {
        if (slot.type === "build_artifact") {
            const str = analyzeBase(env, {type: "uint8array", pos: compilerPos()}, ast, block);
            const res = blockAppend(block, {expr: "comptime:file_create", pos: ast.pos, value: str.value});
            return {type: {type: "build_artifact", pos: compilerPos()}, value: res};
        } else if (slot.type === "uint8array") {
            if (ast.items.length !== 1) throwErr(env, ast.pos, "TODO str items len != 1 todo" + printers.astNode.dumpList(ast.items, 3), [], "todo");
            const it0 = ast.items[0]!;
            if (it0.kind !== "raw" || it0.tag !== "string") throwErr(env, ast.pos, "TODO str item 0 ! raw string" + printers.astNode.dump(it0, 3));
            // if it has aggrandizements it might need runtime construction unless they're all comptime
            // although if it's a uint8array you can't runtime construct the aggrandizements so maybe it should just error
            const unescaped = unescapeString(env, it0.raw, it0.pos);
            const sourcemap: Uint8ArraySourcemapEntry[] = [];
            // TODO: fill out the sourcemap so that we can ask to make an error point to a specific byte of a comptime uint8array
            return {type: {type: "uint8array", pos: compilerPos()}, value: {kind: "uint8array", value: enc.encode(unescaped), sourcemap}};
        } else if (slot.type === "mc:identifier") {
            const str = analyzeBase(env, {type: "uint8array", pos: compilerPos()}, ast, block);
            const u8a = getComptime(env, "uint8array", str.value, ast.pos);
            const decoded = dec.decode(u8a.value);
            const match = decoded.match(/^(?:([-._a-z0-9]+):)?([-._a-z0-9/]+)$/);
            if (!match) throwErr(env, ast.pos, "invalid minecraft identifier name"); // todo point to the specific bad character
            const namespace = match[1] ?? "minecraft";
            const path = match[2]!;
            if (namespace === "..") throwErr(env, ast.pos, "invalid minecraft identifier name");

            return {type: {type: "mc:identifier", pos: compilerPos()}, value: {kind: "mc:identifier", namespace, path}};
        } else if (slot.type === "mc:nbt_ref") {
            const str = analyzeBase(env, {type: "uint8array", pos: compilerPos()}, ast, block);
            const u8a = getComptime(env, "uint8array", str.value, ast.pos);
            const decoded = dec.decode(u8a.value);
            return {type: {type: "mc:nbt_ref", narrow: "string", pos: compilerPos()}, value: {kind: "mc:nbt_ref", type: "string", value: decoded}};
        } else if (slot.type === "c:export_name") {
            const str = analyzeBase(env, {type: "uint8array", pos: compilerPos()}, ast, block);
            const u8a = getComptime(env, "uint8array", str.value, ast.pos);
            const decoded = dec.decode(u8a.value);
            if (!validateCName(decoded)) throwErr(env, ast.pos, "invalid c identifier name", [
                // TODO: "note: invalid character here", pointing to an item of the sourcemap of the uint8array
            ]);
            return {type: {type: "c:export_name", pos: compilerPos()}, value: {kind: "c:export_name", value: decoded as CValidatedIdentifierName}};
        } else {
            throwErr(env, ast.pos, "TODO string in slot: " + printers.type.dump(slot, 3));
        }
    } else if (ast.kind === "raw" && ast.tag === "void") {
        return {type: {type: "void", pos: compilerPos()}, value: {kind: "void"}};
    } else if (ast.kind === "block" && ast.tag === "map") {
        if (slot.type === "build_artifact") {
            const exportsBlock: AnalysisBlock = emptyBlock();
            const arrEntry = blockAppend(exportsBlock, {expr: "comptime:kv_list_init", pos: ast.pos});
            const {env: envInner} = analyzeBlock(env, slot, ast.pos, ast.items, exportsBlock, {
                analyzeBind(env: Env, [lhs, op, rhs]: Binary2, block: AnalysisBlock): AnalysisResult {
                    const key = analyze(env, {type: "uint8array", pos: compilerPos()}, lhs.pos, lhs.items, block);
                    const value = analyze(env, {type: "ast", pos: compilerPos()}, rhs.pos, rhs.items, block);
                    // insert an instruction to append the value to the children list
                    // we could directly append here, but that would preclude `blk: [.a = 1, .b = 2, break :blk, .c = 3]` if we even want to support that
                    const ret = blockAppend(block, {expr: "comptime:kv_list_append", pos: op.pos, list: arrEntry, key: key.value, value: value.value});
                    return {type: {type: "void", pos: compilerPos()}, value: ret};
                    // 
                }
            });
            const arrValue = getComptime(env, "comptime:kv_fields", comptimeEval(env, exportsBlock, arrEntry, ast.pos), ast.pos);
            arrValue.locked = true;

            const registered = new Map<string, {kind: "ok", decl: ComptimeValueDeclaration, pos: TokenPosition} | {kind: "error", etok: ConsumedErrorToken, pos: TokenPosition}>();
            for (const entry of arrValue.entries) {
                const rawKey = getComptime(env, "uint8array", entry.key, entry.pos);
                const value = getComptime(env, "ast", entry.value, entry.pos);
                const key = dec.decode(rawKey.value);
                if (registered.has(key)) {
                    const prevdef = registered.get(key)!;
                    const etok = addErr(env, entry.pos, "duplicate definition", [
                        [prevdef.pos, "previous definition here"],
                    ]);
                    registered.set(key, {kind: "error", etok, pos: prevdef.pos});
                    continue;
                }
                registered.set(key, {kind: "ok", decl: createDeclaration(env, value), pos: entry.pos});
            }

            // now convert to a Map<string, comptimevalue>? maybe?

            const result: ComptimeFolder = {
                kind: "folder",
                value: new Map<string, ComptimeValueBuildArtifact>(),
            };
            for (const [key, value] of registered) {
                if (value.kind === "ok") {
                    const subitm = getComptime(env, "build_artifact", getDeclaration(env, value.decl).value, value.pos);
                    result.value.set(key, subitm);
                } else {
                    throwConsumedErr(value.etok);
                }
            }
            return {type: {type: "build_artifact", narrow: "folder", pos: ast.pos}, value: {kind: "build_artifact", value: result}};
        } else if (slot.type === "export_list") {
            const exportsBlock: AnalysisBlock = emptyBlock();
            const arrEntry = blockAppend(exportsBlock, {expr: "comptime:kv_list_init", pos: ast.pos});
            const {env: envInner} = analyzeBlock(env, slot, ast.pos, ast.items, exportsBlock, {
                analyzeBind(env: Env, [lhs, op, rhs]: Binary2, block: AnalysisBlock): AnalysisResult {
                    const key = analyze(env, slot.key, lhs.pos, lhs.items, block);
                    const value = analyze(env, {type: "ast", pos: compilerPos()}, rhs.pos, rhs.items, block);
                    // insert an instruction to append the value to the children list
                    // we could directly append here, but that would preclude `blk: [.a = 1, .b = 2, break :blk, .c = 3]` if we even want to support that
                    const ret = blockAppend(block, {expr: "comptime:kv_list_append", pos: op.pos, list: arrEntry, key: key.value, value: value.value});
                    return {type: {type: "void", pos: compilerPos()}, value: ret};
                    // 
                }
            });
            const arrValue = getComptime(env, "comptime:kv_fields", comptimeEval(env, exportsBlock, arrEntry, ast.pos), ast.pos);
            arrValue.locked = true;

            // now convert to a Map<string, comptimevalue>? maybe?

            const result: ComptimeValueExportList = {
                kind: "export_list",
                exports: [],
            };

            for (const entry of arrValue.entries) {
                const value = getComptime(env, "ast", entry.value, entry.pos);
                result.exports.push({key: entry.key, keyPos: entry.pos, value});
            }

            return {type: {type: "export_list", key: slot.key, pos: ast.pos}, value: result};

        } else {
            throwErr(env, ast.pos, "TODO map in slot: "+printers.type.dump(slot, 3));
        }
    } else if (ast.kind === "block" && ast.tag === "code") {
        const res = analyzeBlock(env, slot, ast.pos, ast.items, block, {analyzeBind(env, [lhs, op, rhs], block) {
            throwErr(env, op.pos, "TODO: implement bind in block");
        }});
        return res.result;
    } else if (ast.kind === "ident" && ast.identTag === "number") {
        if (slot.type === "mc:result") {
            const parsed = +ast.str;
            if (("" + (parsed |0)) !== ast.str) throwErr(env, ast.pos, `invalid i32: expected '${"" + (parsed |0)}', got '${ast.str}'`);
            return {type: {type: "mc:result", pos: ast.pos, narrow: "i32"}, value: {kind: "mc:result", result: parsed}};
        }
        throwErr(env, ast.pos, "TODO support number in slot: " + slot.type);
    } else if (ast.kind === "binary" && ast.tag === "assign") {
        const rbr = readBinary2(env, [ast], "assign");
        if (!rbr) throwErr(env, ast.pos, "Expected X = Y, got X = Y = Z? " + printers.astNode.dumpList(ast.items));
        const [lhs, op, rhs] = rbr;
        const destructure = readDestructure(env, lhs.pos, lhs.items);
        const body = analyze(env, destructure.type, rhs.pos, rhs.items, block);
        const bindings = analyzeDestructure(env, destructure, body, block);
        if (bindings.length > 0) throwErr(env, lhs.pos, "TODO implement assignment operator");
        return {type: {type: "void", pos: lhs.pos}, value: {kind: "void"}};
    } else {
        throwErr(env, ast.pos, "TODO analyzeBase: "+ast.kind+printers.astNode.dumpList([ast], 3));
    }
}
function analyzeDestructure(env: Env, destructure: Destructure, body: AnalysisResult, block: AnalysisBlock): AnalysisResult[] {
    const targets: (AnalysisResult | undefined)[] = [];
    analyzeDestructureInner(env, destructure.extract, body, block, targets);
    if (!targets.every(t => !!t)) throw new Error("unreachable");
    if (targets.length !== destructure.targets.length) throw new Error("unreachable");
    return targets as AnalysisResult[];
}
function analyzeDestructureInner(env: Env, extract: DestructureExtract, body: AnalysisResult, block: AnalysisBlock, targets: (AnalysisResult | undefined)[]) {
    if (extract.kind === "single_item") {
        if (targets[extract.target]) throw new Error("unreachable!");
        targets[extract.target] = body;
    } else if (extract.kind === "discard") {
        // discard body
    } else throwErr(env, extract.pos, "TODO support extract: " + printers.destructureExtract.dump(extract));
}
const enc = new TextEncoder();
const dec = new TextDecoder();
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
export type DestructureTag = {
    kind: "callconv",
    pos: TokenPosition,
} | {
    kind: "error",
    pos: TokenPosition,
    tok: ConsumedErrorToken,
};
export type DestructureTarget = {name: string, pos: TokenPosition};
export type Destructure = {
    targets: DestructureTarget[],
    extract: DestructureExtract,
    type: ComptimeType,
    tags: DestructureTag[],
};
export type DestructureExtract = {
    kind: "single_item",
    target: number,
    pos: TokenPosition,
} | {
    kind: "list",
    items: DestructureExtract[],
    pos: TokenPosition,
} | {
    kind: "map",
    items: [ComptimeValueKey, DestructureExtract][],
    pos: TokenPosition,
} | {
    kind: "discard",
    pos: TokenPosition,
};
function readDestructure(env: Env, pos: TokenPosition, src: SyntaxNode[], targets: DestructureTarget[] = []): Destructure {
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
    let lhsItems = trimWs(src);
    const rawTags = lhsItems.filter(itm => itm.kind === "ident" && itm.identTag === "builtin");
    lhsItems = lhsItems.filter(itm => !(itm.kind === "ident" && itm.identTag === "builtin"));
    if (lhsItems.length < 1) throwErr(env, pos, "Expected at least one item to destructure" + printers.astNode.dumpList(src, 2));

    let type: ComptimeType | undefined;
    {
        const last = lhsItems[lhsItems.length - 1]!;
        if (last.kind === "block" && last.tag === "colon_call") {
            // for setting the type
            const block = emptyBlock();
            const body = analyze(env, {type: "type", pos: compilerPos()}, last.pos, last.items, block);
            const analyzed = comptimeEval(env, block, body.value, last.pos);
            type = getComptime(env, "type", analyzed, last.pos).type;
        }
    }

    if (lhsItems.length > 1) throwErr(env, lhsItems[1]!.pos, "Unexpected item for destructuring. TODO support eg 'name: type := value'" + printers.astNode.dumpList(src, 2));

    const processedTags = rawTags.map((tag): DestructureTag => {
        if (tag.kind === "ident" && tag.str === "callconv_c") {
            return {
                kind: "callconv",
                pos: tag.pos,
            };
        } else {
            return {
                kind: "error",
                pos: tag.pos,
                tok: addErr(env, tag.pos, "Bad tag: "+printers.astNode.dump(tag, 3)),
            };
        }
    });

    const ident = lhsItems[0]!;
    if (ident.kind === "ident" && ident.identTag === "normal") {
        return {
            extract: {kind: "single_item", target: targets.push({name: ident.str, pos: ident.pos}) - 1, pos: ident.pos},
            type: type ?? {type: "unknown", pos: ident.pos},
            tags: [],
            targets,
        };
    } else if (ident.kind === "ident" && ident.identTag === "discard") {
        return {
            extract: {kind: "discard", pos: ident.pos},
            type: {type: "unknown", pos: ident.pos},
            tags: [],
            targets,
        };
    } else if (ident.kind === "block" && ident.tag === "list") {
        const args = readBinary(env, ident.pos, ident.items, "sep");
        const extracts: DestructureExtract[] = [];
        const types: ComptimeType[] = [];
        for (const arg of args) {
            if (arg.items.length === 0) continue; // TODO: we should allow `[a\n\nb]` but disallow `[a,,b]`
            const sub = readDestructure(env, arg.pos, arg.items, targets);
            extracts.push(sub.extract);
            types.push(sub.type);
        }
        if (type) throwErr(env, ident.pos, "TODO support setting type on block in destructure");
        return {
            extract: {kind: "list", items: extracts, pos: ident.pos},
            type: {type: "tuple", children: types, pos: ident.pos},
            tags: [],
            targets,
        };
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
    for (const lineRaw of lines) {
        try {
            const lineItems = trimWs(lineRaw.items);
            if (lineItems.length === 0) continue;
            const rb2 = readBinary2(env, lineItems, "def");
            if (rb2) {
                // found binding
                const [lhs, op, rhs] = rb2;
                const destructure = readDestructure(env, lhs.pos, lhs.items);
                if (destructure.extract.kind !== "single_item") throwErr(env, destructure.extract.pos, "TODO: support multiple destructure targets using analyzeDestructure(), called when any of the names is resolved (but if two multiple names are resolved, called only once)");
                for (const target of destructure.targets) {
                    const prev = subscope.bindings.get(target.name);
                    if (prev) {
                        // ideally we would prevent posting the error if the value is already an error
                        const tok = addErr(env, destructure.extract.pos, `Duplicate binding name ${target.name}`, [
                            [prev.pos, "Previous definition here"],
                        ]);
                        subscope.bindings.set(target.name, {pos: prev.pos, kind: "error", consumed: tok});
                    } else {
                        
                        subscope.bindings.set(target.name, {pos: op.pos, kind: "valid", decl: createDeclaration(env, {
                            kind: "ast",
                            ast: rhs!.items,
                            pos: rhs!.pos,
                            env,
                        })});
                    }
                }
            } else {
                // found non-binding
                res.lines.push(lineRaw);
            }
        } catch (err) {
            handleErr(env, err);
        }
    }
    return res;
}
function trimWs(src: SyntaxNode[]): SyntaxNode[] {
    return src.filter(itm => !((itm.kind === "ws") || (itm.kind === "block" && itm.tag === "inline_comment")));
}
type Binary2 = [OperatorSegmentToken, OperatorToken, OperatorSegmentToken];
function readBinary2(env: Env, rootSrc: SyntaxNode[], kw: OpTag): Binary2 | undefined {
    rootSrc = trimWs(rootSrc);
    if (rootSrc.length === 0) return undefined;
    if (rootSrc[0]!.kind !== "binary" || rootSrc[0]!.tag !== kw) return undefined;
    const src = trimWs(rootSrc[0]!.items);
    if (src.length !== 3) return throwErr(env, rootSrc[0]!.pos, "Expected LHS op RHS, found not that");
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