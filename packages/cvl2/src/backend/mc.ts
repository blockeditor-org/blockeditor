import { compilerPos, throwErr, type AnalysisBlock, type ComptimeValueFn, type ComptimeValueMcIdentifier, type Env, type RuntimeValue } from "../cmpyl";
import { getComptime } from "../cte";
import { printers } from "../printers";

/*
runCommand should require arguments:
- location (eg /execute positioned 1.0 2.0 3.0 rotated 4.0 5.0 in minecraft:the_nether)
- entities (eg /execute as @p)
- aka CommandSourceStack in the code: https://mcsrc.dev/1/26.1.2/net/minecraft/commands/CommandSourceStack
  - vec3 worldPosition, dimension level, entity entity, anchor anchor, vec2 rotation 
  - we combine four of those into one

so eg:
- main :: (loc: mc.Location, self: mc.Entity, macroArg: mc.NBT(.unknown))
  - _ = mc.Result: mc.runCommand(.at = &pos, .as = &self, .cmd = "say hi")
  - it's &self because runCommand accepts an EntitiesRef (a Selector), but when you call a function you recieve just a single entity
  - same with &loc
  - in codegen, these resolve to '@s' and '~ ~ ~' (assuming they haven't been clobbered, in which case they error at codegen)
*/

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
            const execValue = getComptime(env, "mc:nbt_ref", line.command, line.pos);
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
export type ComptimeValueMcNbtRef = {
    kind: "mc:nbt_ref",
    type: "string",
    value: string,
} | {
    kind: "mc:nbt_ref",
    type: "source",
    source: {
        type: "storage",
        storage: ComptimeValueMcIdentifier,
        path: string,
    } | {
        type: "entity",
        selector: ComptimeValueMcEntitiesRef,
        path: string,
    } | {
        type: "block",
        position: ComptimeValueMcPositionRef,
        path: string,
    },
};
export type ComptimeValueMcEntitiesRef = {
    kind: "mc:entities_ref",
    main: "s" | "p" | "a" | "r" | "e",
    parameters: Map<string, string>,
};
export type ComptimeValueMcPositionRef = {
    kind: "mc:position_ref",
    type: "absrel",
    x: number,
    xRel: boolean,
    y: number,
    yRel: boolean,
    z: number,
    zRel: boolean,
} | {
    kind: "mc:position_ref",
    type: "^",
    x: number,
    y: number,
    z: number,
    anchor: "eyes" | "feet", // default is feet
};
export type ComptimeValueMcLocation = {
    kind: "mc:location",
    position: ComptimeValueMcPositionRef,
    rotation: ComptimeValueMcRotationRef,
    dimension?: ComptimeValueMcIdentifier,
};
export type ComptimeValueMcRotationRef = {
    kind: "mc:rotation_ref",
    type: "absrel",
    x: number,
    xRel: number,
    y: number,
    yRel: number,
} | {
    kind: "mc:rotation_ref",
    type: "as",
    selector: ComptimeValueMcEntitiesRef,
};

export type ComptimeValueMc = ComptimeValueMcNbtRef | ComptimeValueMcEntitiesRef | ComptimeValueMcPositionRef | ComptimeValueMcResult | ComptimeValueMcLocation | ComptimeValueMcRotationRef;