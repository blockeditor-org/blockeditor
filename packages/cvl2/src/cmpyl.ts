import { prettyPrintErrors, renderTokenizedOutput, Source, tokenize, type OperatorSegmentToken, type OperatorToken, type PrecString, type SyntaxNode, type TokenizationError, type TokenizationErrorEntry, type TokenPosition } from "./cvl2";

class PositionedError extends Error {
    e: TokenizationError;
    constructor(e: TokenizationError) {
        super([...e.entries.map(nt => `${nt.pos?.fyl ?? "???"}:${nt.pos?.lyn ?? "???"}:${nt.pos?.col ?? "???"}: ${nt.style}: ${nt.message}`), ...e.trace.map(t => ` at ${t.fyl}:${t.lyn}:${t.col}`)].join("\n"));
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
    
    const env: Env = {
        trace: [],
        errors: [...tokenized.errors],
    };
    try {
        analyzeNamespace(env, {fyl: filename, lyn: 0, col: 0, idx: 0}, tokenized.result);
    }catch(err) {
        handleErr(env, err);
    }
    
    if (env.errors.length > 0) {
        console.log(prettyPrintErrors(sourceCode, env.errors));
        process.exit(1);
    }
}

type Env = {
    trace: TokenPosition[],
    errors: TokenizationError[],
};
type ComptimeNamespace = {
    _?: undefined,
};
function analyzeNamespace(env: Env, pos: TokenPosition, src: SyntaxNode[]): ComptimeNamespace {
    const block: AnalysisBlock = {
        lines: [],
    };
    const analyzeBindEntries = new Map<string | symbol, unknown>();
    analyzeBlock(env, {type: "void", pos: compilerPos()}, pos, src, block, {
        analyzeBind(env, [lhs, op, rhs], block): AnalysisResult {
            const key = analyze(env, {type: "key", pos: compilerPos()}, lhs.pos, lhs.items, block);
            if (key.type.type !== "key") throw new Error("unreachable");
            if (!key.type.narrow) throwErr(env, lhs.pos, "Expected narrowed key, got un-narrowed key");
            // ^ this means eg:
            // `let a: comptime_key = .abc; a := 25` -> this fails because a is not narrowed
            // `let a: comptime_key[.abc] = .abc; a := 25` -> this succeeds
            // strange. odd behaviour here. it's fine though i guess?
            const value = analyze(env, {type: "ast", pos: compilerPos()}, rhs.pos, rhs.items, block);
            throwErr(env, op.pos, "TODO complete analyzeBind implementation");
        },
    });
    /*
    are we ruined by going this route?
    - the route being one that requires comptime evaluating the block contents before we post the fields

    A :: ns [
        .three := B.two + 1
        .one := 1
    ]
    B :: ns [
        .two := A.one + 1
    ]
    yes we're ruined aren't we
    because we're analyzing A
    wait no it's fine actually because := bodies are lazy already
    the only time there's a dep loop is:
    A :: ns [
        let three = B.two + 1
        .three := three
        .one = 1
    ]
    B :: ns [
        let two = A.one + 1
        .two := 
    ]
    there's a dep loop there because we're analyzing the line 'let three = B.two'
    so then we analyze B, so we analyze let two = A.one, so then we analyze A = dep loop
    ok so we're actually fine maybe??
    */
    return {};
}
function analyzeBlock(env: Env, slot: ComptimeType, pos: TokenPosition, src: SyntaxNode[], block: AnalysisBlock, cfg: {
    analyzeBind(env: Env, b2: Binary2, block: AnalysisBlock): AnalysisResult,
}): AnalysisResult {
    const container = readContainer(env, pos, src);
    
    for (const line of container.lines) {
        // execute lines
        const rb2 = readBinary2(env, line.items, "bind", ":=");
        if (!rb2) {
            console.log(line.items);
            throw new Error("debug: why did readbinary2 fail here?");
        }
        if (rb2) {
            // have the caller analyze the bind
            cfg.analyzeBind(env, rb2, block);
        } else {
            // analyze the line
            analyze(env, {type: "void", pos: line.pos}, line.pos, line.items, block);
        }
    }


    block.lines.push({expr: "void"});
    return {idx: block.lines.length - 1, type: {type: "void", pos: pos}};
}
type ComptimeTypeVoid = {type: "void", pos: TokenPosition};
type ComptimeTypeKey = {
    type: "key", pos: TokenPosition,
    narrow?: {
        type: "symbol",
        symbol: symbol,
        child: ComptimeType,
    } | {
        type: "string",
        string: string,
    },
};
type ComptimeTypeAst = {
    type: "ast", pos: TokenPosition,
};
type ComptimeType = ComptimeTypeVoid | ComptimeTypeKey | ComptimeTypeAst;

type ComptimeValueAst = {
    ast: SyntaxNode[],
};

type AnalysisLine = {
    expr: "ct:ast",
    value: ComptimeValueAst,
} | {
    expr: "void",
};
type AnalysisBlock = {
    lines: AnalysisLine[],
};
type AnalysisResult = {
    idx: number,
    type: ComptimeType,
};
function blockAppend(block: AnalysisBlock, instr: AnalysisLine): number {
    block.lines.push(instr);
    return block.lines.length - 1;
}
function analyze(env: Env, slot: ComptimeType, pos: TokenPosition, ast: SyntaxNode[], block: AnalysisBlock): AnalysisResult {
    if (slot.type === "ast") {
        const value: ComptimeValueAst = {ast: ast};
        const idx = blockAppend(block, {expr: "ct:ast", value});
        return {idx: idx, type: {
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
    throwErr(env, ast[0]?.pos ?? pos, "TODO analyze "+(ast[0]?.kind));
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
function readContainer(env: Env, pos: TokenPosition, src: SyntaxNode[]): ReadContainer {
    const lines: {items: SyntaxNode[], pos: TokenPosition}[] = readBinary(env, src, "sep") ?? [{items: src, pos: pos}];
    const res: ReadContainer = {
        bindings: new Map(),
        lines: [],
    };
    for (const line of lines) {
        try {
            if (line.items.length === 0) continue;
            const rb2 = readBinary2(env, line.items, "bind", "::");
            if (rb2) {
                // found binding
                const [lhs, op, rhs] = rb2;
                const lhsItems = trimWs(lhs!.items);
                if (lhsItems.length < 1) throwErr(env, lhs!.pos, "Expected ident for bind");
                const ident = lhsItems[0]!;
                if (ident.kind !== "ident") throwErr(env, ident.pos, `Expected ident for bind lhs, found ${ident.kind}`);
                if (lhsItems.length > 1) throwErr(env, lhsItems[1]!.pos, "Unexpected trailing item in bind lhs");
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
function readBinary2(env: Env, rootSrc: SyntaxNode[], cat: PrecString, kw: string): Binary2 | undefined {
    rootSrc = trimWs(rootSrc);
    if (rootSrc.length === 0) return undefined;
    if (rootSrc[0]!.kind !== "binary" || rootSrc[0]!.precStr !== cat) return undefined;
    const src = trimWs(rootSrc[0]!.items);
    if (src.length !== 3) return undefined;
    const [lhs, op, rhs] = src;
    if (lhs?.kind !== "opSeg" || op?.kind !== "op" || rhs?.kind !== "opSeg") return undefined;
    if (op.op !== kw) return undefined;
    return [lhs, op, rhs];
}
function readBinary(env: Env, src: SyntaxNode[], cat: PrecString): OperatorSegmentToken[] | undefined {
    src = trimWs(src);
    if (src.length === 0) return undefined;
    if (src[0]!.kind !== "binary" || src[0]!.precStr !== cat) return undefined;
    if (src.length > 1) throwErr(env, src[1]!.pos, "Found extra trailing items while parsing readBinary");
    return src[0]!.items.flatMap((itm): OperatorSegmentToken[] => {
        if (itm.kind === "opSeg") return [itm];
        if (itm.kind === "op") return [];
        throwErr(env, itm.pos, `Unexpected token in ${cat}: ${itm.kind}`);
    });
}
function throwErr(env: Env, pos: TokenPosition | undefined, msg: string, notes?: [pos: TokenPosition | undefined, msg: string][]): never {
    throw new PositionedError(getErr(env, pos, msg, notes))
}
function addErr(env: Env, pos: TokenPosition | undefined, msg: string, notes?: [pos: TokenPosition | undefined, msg: string][]): void {
    env.errors.push(getErr(env, pos, msg, notes))
}
function getErr(env: Env, pos: TokenPosition | undefined, msg: string, notes?: [pos: TokenPosition | undefined, msg: string][]): TokenizationError {
    throw new PositionedError({
        entries: [
            {pos: pos, style: "error", message: msg},
            ...(notes ?? []).map((note): TokenizationErrorEntry => ({pos: note[0], style: "note", message: note[1]}))
        ],
        trace: env.trace,
    })
}
function handleErr(env: Env, err: unknown): void {
    if (err instanceof PositionedError) {
        env.errors.push(err.e);
    }else{
        throw err;
    }
}
function assert(a: boolean): asserts a {
    if (!a) throw new Error("assertion failed");
}

if(import.meta.main) {
    importFile("packages/cvl2/src/demo.qxc", await Bun.file(import.meta.dir + "/demo.qxc").text());
}