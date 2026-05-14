import { compilerPos, throwErr, type AnalysisBlock, type ComptimeValueFn, type ComptimeValueMcIdentifier, type Env, type RuntimeValue } from "../cmpyl";
import { getComptime } from "../cte";
import { printers } from "../printers";

export type McCodegenCtx = {
    fns: Map<ComptimeValueFn, ComptimeValueMcIdentifier>,
    gid: number,
    internalNs: string,
};
function getFnName(ctx: McCodegenCtx, fn: ComptimeValueFn): ComptimeValueMcIdentifier {
    // TODO: take a hint from the fn name, which we should include in ComptimeValueFn.
    // TODO: use a hash of the content (2-pass but shouldn't be too hard)
    if (ctx.fns.has(fn)) return ctx.fns.get(fn)!;
    const res: ComptimeValueMcIdentifier = {kind: "mc:identifier", namespace: ctx.internalNs, path: `_${ctx.gid++}`};
    ctx.fns.set(fn, res);
    return res;
}
export function codegenMcfunction(env: Env, ctx: McCodegenCtx, block: AnalysisBlock, value: RuntimeValue): string {
    console.log("codegenMcfunction.block", printers.block.dump(block));
    console.log("codegenMcfunction.value", printers.runtimeValue.dump(value));

    const lines: string[] = [];
    let pure: string[] = [];
    for (const [i, line] of block.lines.entries()) {
        if (line.expr === "args") {
            // nothing to do
        } else if (line.expr === "call") {
            // we can add runtime support later, ie for dynamic dispatch
            const methodComptime = getComptime(env, "fn", line.method, line.pos);
            const methodName = getFnName(ctx, methodComptime);
            pure[i] = "function " + methodName.namespace + ":" + methodName.path;
        } else if (line.expr === "mc:exec_raw") {
            // we can add runtime support later, ie /function ($$(nbt prop)) with nbt source
            const execValue = getComptime(env, "mc:nbt", line.command, line.pos);
            if (execValue.type === "string") {
                lines.push(execValue.value);
            } else throwErr(env, line.pos, "TODO runCommand: " + printers.runtimeValue.dump(execValue));
        } else {
            throwErr(env, line.pos, "TODO codegenMcfunction line: " + printers.block.dump(block));
        }
    }
    if (value.kind === "mc:result") {
        lines.push("return " + value.result);
    } else if (value.kind === "runtime") {
        if (pure[value.idx]) return `return ${pure[value.idx]}`;
        throwErr(env, compilerPos(), "TODO return");
    } else {
        throwErr(env, compilerPos(), "TODO codegenMcfunction result: " + printers.runtimeValue.dump(value));
    }
    return lines.join("\n");
}


export type ComptimeValueMcResult = {
    kind: "mc:result",
    result: number | "fail",
};
export type ComptimeValueMcNbt = {
    kind: "mc:nbt",
    type: "string",
    value: string,
} | {
    kind: "mc:nbt",
    type: "source",
    source: {
        type: "storage",
        storage: ComptimeValueMcIdentifier,
        path: string,
    } | {
        type: "entity",
        selector: ComptimeValueMcSelector,
        path: string,
    } | {
        type: "block",
        position: ComptimeValueMcPosition,
        path: string,
    },
};
export type ComptimeValueMcSelector = {
    kind: "mc:selector",
    main: "s" | "p" | "a" | "r" | "e",
    parameters: Map<string, string>,
};
export type ComptimeValueMcPosition = {
    kind: "mc:position",
    type: "main",
    x: number,
    xRel: boolean,
    y: number,
    yRel: boolean,
    z: number,
    zRel: boolean,
} | {
    kind: "mc:position",
    type: "^",
    x: number,
    y: number,
    z: number,
};

export type ComptimeValueMc = ComptimeValueMcNbt | ComptimeValueMcSelector | ComptimeValueMcPosition | ComptimeValueMcResult;