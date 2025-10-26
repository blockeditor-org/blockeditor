import { prettyPrintErrors, renderTokenizedOutput, Source, tokenize, type OperatorSegmentToken, type PrecString, type SyntaxNode, type TokenizationError, type TokenizationErrorEntry, type TokenPosition } from "./cvl2";

class PositionedError extends Error {
    e: TokenizationError;
    constructor(e: TokenizationError) {
        super([...e.entries.map(nt => `${nt.pos?.fyl ?? "???"}:${nt.pos?.lyn ?? "???"}:${nt.pos?.col ?? "???"}: ${nt.style}: ${nt.message}`), ...e.trace.map(t => ` at ${t.fyl}:${t.lyn}:${t.col}`)].join("\n"));
        this.e = e;
    }
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
        analyzeNamespace(env, tokenized.result);
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
function analyzeNamespace(env: Env, src: SyntaxNode[]): ComptimeNamespace {
    const container = readContainer(env, src);
    for (const line of container.lines) {
        // not true! we'll need to be able to define exports
        // ie #builtin.main = abc
        env.errors.push(getErr(env, line.items[0]?.pos, "A container must only consist of bindings; no lines"));
    }
    console.log(container);

    return {};
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
    lines: {items: SyntaxNode[]}[],
};
function readContainer(env: Env, src: SyntaxNode[]): ReadContainer {
    const lines: {items: SyntaxNode[]}[] = readBinary(env, src, "semi") ?? [{items: src}];
    const res: ReadContainer = {
        bindings: new Map(),
        lines: [],
    };
    for (const line of lines) {
        try {
            if (line.items.length === 0) continue;
            const itm = readBinary(env, line.items, "bind");
            if (itm) {
                // found binding
                if (itm.length < 2) err(env, itm[0]?.pos, "Expected 2 for binding, found 1");
                if (itm.length > 2) err(env, itm[2]!.pos, "Expected 2 for binding, found 1");
                const [lhs, rhs] = itm;
                const lhsItems = trimWs(lhs!.items);
                if (lhsItems.length < 1) err(env, lhs!.pos, "Expected ident for bind");
                const ident = lhsItems[0]!;
                if (ident.kind !== "ident") err(env, ident.pos, `Expected ident for bind lhs, found ${ident.kind}`);
                if (lhsItems.length > 1) err(env, lhsItems[1]!.pos, "Unexpected trailing item in bind lhs");
                const prev = res.bindings.get(ident.str);
                if (prev) {
                    // ideally we would prevent posting the error if the value is already an error
                    addErr(env, ident.pos, `Duplicate binding name ${ident.str}`, [
                        [prev.pos, "Previous definition here"],
                    ]);
                    res.bindings.set(ident.str, {pos: prev.pos, value: [{kind: "err", pos: prev.pos}]});
                } else {
                    res.bindings.set(ident.str, {pos: ident.pos, value: rhs!.items});
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
function readBinary(env: Env, src: SyntaxNode[], cat: PrecString): OperatorSegmentToken[] | undefined {
    src = trimWs(src);
    if (src.length === 0) return undefined;
    if (src[0]!.kind !== "binary" || src[0]!.precStr !== cat) return undefined;
    if (src.length > 1) err(env, src[1]!.pos, "Found extra trailing items while parsing readBinary");
    return src[0]!.items.flatMap((itm): OperatorSegmentToken[] => {
        if (itm.kind === "opSeg") return [itm];
        if (itm.kind === "op") return [];
        err(env, itm.pos, `Unexpected token in ${cat}: ${itm.kind}`);
    });
}
function err(env: Env, pos: TokenPosition | undefined, msg: string, notes?: [pos: TokenPosition | undefined, msg: string][]): never {
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

if(import.meta.main) {
    importFile("packages/cvl2/src/demo.qxc", await Bun.file(import.meta.dir + "/demo.qxc").text());
}