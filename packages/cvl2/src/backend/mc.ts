import { compilerPos, throwErr, type AnalysisBlock, type ComptimeValueFn, type ComptimeValueMcIdentifier, type Env, type RuntimeValue } from "../cmpyl";
import { getComptime } from "../cte";
import type { TokenPosition } from "../cvl2";
import { printers } from "../printers";

/*
compilation:
- saving variables in a stack
- saving entities in a stack: tag the entity, store it in the stack
  - ie tag the entity with a cfg.prefix.tmp_$(index) tag
  - and increment global index every time
  - or we can do the scoreboard method where we give the entity a score and filter for it
if we do this, then:
    r1 := std.mc.runCommand: "say \"Hello\""
    r2 := std.mc.runCommand: "say \"Goodbye\""
    -> r1
would compile to
    // function header
    execute if score temp(cfg.prefix).$fn$0 matches 1 run {
        // this is a sub-call to this function, we need to stash the values and restore them before exit
    }

    execute store result temp(cfg.prefix).$fn$1 store success temp.$fn$2 run say Hello
    execute store result temp(cfg.prefix).$fn$3 store success temp.$fn$4 run say Hello

    // Result to Return:
    execute if score temp.$fn2 matches 0 run return fail
    execute store result data storage cfg.namespace:$fn.call.a0 run scoreboard players get temp(cfg.prefix).$fn$2
    return run function {
        function $restore
        return $(a0)
    } with cfg.namespace:temp.call
    $restore: {
        execute unless data storage cfg.namespace:$fn.stack run return 1
        execute store result temp(cfg.prefix).$fn.len run data get storage cfg.namespace:$fn.stack
        scoreboard players remove temp(cfg.prefix).$fn.len 1
        with {idx} function {
            tmp_data = stack[idx]
            delete stack[idx]
        }
        // ... restore variable & data values from stack
        $fn$1 = stack.1
        $fn$2 = stack.2
        // ...
    }
// ... yikes. that sucks.
// ideally in some cases we could optimize it to be better. like:
// - if you returned the second result, we don't need to store the results
// - if the function's call tree is known at render(build) time to not call itself, we can skip the function header and footer
//   - or if it features no temporary variables
// but geez.

alternate method: we don't automatically do any of that stuff, but we allow it to be done manually:
r1 := std.mc.runCommand: "say Hello"
a := std.mc.score: r1.success
b := std.mc.score: r1.result
_ = std.mc.runCommand: "say Goodbye"
if (a != 0) { return: .fail }
-> ((std.mc.Args({result: Int})) => {
    -> result
})(std.mc.nbt: {
    result: b,
})

still bad
*/

/*
here's how selectors should work:
- there is the EntityQuery and the EntityList
- you can execute an EntityQuery to get an EntityList
- an EntityQuery is eg '@s' or '@e[tag=...]'. an EntityList is the actual executed value
*/

/*
runCommand should require arguments:
- location (eg /execute positioned 1.0 2.0 3.0 rotated 4.0 5.0 in minecraft:the_nether)
- entities (eg /execute as @p)
- aka CommandSourceStack in the code: https://mcsrc.dev/1/26.1.2/net/minecraft/commands/CommandSourceStack
  - vec3 worldPosition, dimension level, entity entity, anchor anchor, vec2 rotation 
  - we combine four of those into one

so eg:
    main :: (loc: mc.Location, self: mc.Entity, macroArg: mc.NBT(.unknown))
        _ = mc.Result: mc.runCommand(.at = &pos, .as = &self, .cmd = "say hi")
  - it's &self because runCommand accepts an EntitiesRef (a Selector), but when you call a function you recieve just a single entity
  - same with &loc
  - in codegen, these resolve to '@s' and '~ ~ ~' (assuming they haven't been clobbered, in which case they error at codegen)
  - but note that if you do this, it will resolve to @s still
      self_ref := &self
      mc.execute.as(mc.world.allEntities().filterTag("abc")).at(self_ref) <- it will use 'at @s' here
      mc.execute.as(mc.world.allEntities().filterTag("abc")).at(&self) <- this is ok, it will just error
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

    const _rawLines: string[] = [];
    let lostPositions: TokenPosition[] = [];
    let uncommittedLine: {idx?: number, cmd: string} | undefined;
    function addLine(idx: number | undefined, pos: TokenPosition, cmd: string) {
        if (uncommittedLine) {
            _rawLines.push(uncommittedLine.cmd);
            if (uncommittedLine.idx) lostPositions[uncommittedLine.idx] = pos;
        }
        uncommittedLine = {idx, cmd};
    }
    for (const [i, line] of block.lines.entries()) {
        if (line.expr === "args") {
            // nothing to do
        } else if (line.expr === "call") {
            // we can add runtime support later, ie for dynamic dispatch
            const methodComptime = getComptime(env, "fn", line.method, line.pos);
            const methodName = getFnName(ctx, methodComptime);
            addLine(i, line.pos, "function " + methodName.namespace + ":" + methodName.path);
        } else if (line.expr === "mc:exec_raw") {
            // we can add runtime support later, ie /function ($$(nbt prop)) with nbt source
            const execValue = getComptime(env, "mc:nbt_ref", line.command, line.pos);
            if (execValue.type === "string") {
                addLine(i, line.pos,execValue.value);
            } else throwErr(env, line.pos, "TODO runCommand: " + printers.runtimeValue.dump(execValue));
        } else {
            throwErr(env, line.pos, "TODO codegenMcfunction line: " + printers.block.dump(block));
        }
    }
    if (value.kind === "mc:result") {
        addLine(undefined, compilerPos(), "return " + value.result);
    } else if (value.kind === "runtime") {
        if (uncommittedLine?.idx === value.idx) {
            uncommittedLine.cmd = `return run ${uncommittedLine.cmd}`;
        } else {
            throwErr(env, compilerPos(), "this result was lost", [
                [block.lines[value.idx]!.pos, "acquired here"],
                [lostPositions[value.idx] ?? compilerPos(), "lost here"],
            ]); // todo: add a 'lost here' note
        }            
    } else {
        throwErr(env, compilerPos(), "TODO codegenMcfunction result: " + printers.runtimeValue.dump(value));
    }
    if (uncommittedLine) _rawLines.push(uncommittedLine.cmd);
    return _rawLines.join("\n");
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

/*

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
    argument_type: {
        // https://minecraft.wiki/w/Argument_types
        // types used for arguments in commands
        "brigader:bool": blockTypeSym<null>(),
        "brigader:double": blockTypeSym<null>(),
        "brigader:float": blockTypeSym<null>(),
        "brigader:integer": blockTypeSym<null>(),
        "brigadier:long": blockTypeSym<null>(),
        "brigadier:string": blockTypeSym<"word" | "phrase" | "greedy">(),
        "minecraft:angle": blockTypeSym<null>(),
        "minecraft:block_pos": blockTypeSym<null>(),
        "minecraft:block_predicate": blockTypeSym<null>(),
        "minecraft:block_state": blockTypeSym<null>(),
        "minecraft:color": blockTypeSym<null>(),
        "minecraft:column_pos": blockTypeSym<null>(),
        "minecraft:component": blockTypeSym<null>(),
        "minecraft:dimension": blockTypeSym<null>(),
        "minecraft:entity": blockTypeSym<null>(),
        "minecraft:entity_anchor": blockTypeSym<null>(),
        "minecraft:float_range": blockTypeSym<null>(),
        "minecraft:function": blockTypeSym<null>(),
        "minecraft:game_profile": blockTypeSym<null>(),
        "minecraft:gamemode": blockTypeSym<null>(),
        "minecraft:heightmap": blockTypeSym<null>(),
        "minecraft:int_range": blockTypeSym<null>(),
        "minecraft:item_predicate": blockTypeSym<null>(),
        "minecraft:item_slot": blockTypeSym<null>(),
        "minecraft:item_slots": blockTypeSym<null>(),
        "minecraft:item_stack": blockTypeSym<null>(),
        "minecraft:loot_modifier": blockTypeSym<null>(),
        "minecraft:loot_predicate": blockTypeSym<null>(),
        "minecraft:loot_table": blockTypeSym<null>(),
        "minecraft:message": blockTypeSym<null>(),
        "minecraft:nbt_compound_tag": blockTypeSym<null>(),
        "minecraft:nbt_path": blockTypeSym<null>(),
        "minecraft:nbt_tag": blockTypeSym<null>(),
        "minecraft:objective": blockTypeSym<null>(),
        "minecraft:objective_criteria": blockTypeSym<null>(),
        "minecraft:operation": blockTypeSym<null>(),
        "minecraft:particle": blockTypeSym<null>(),
        "minecraft:resource": blockTypeSym<{registry: string}>(),
        "minecraft:resource_key": blockTypeSym<{registry: string}>(),
        "minecraft:resource_location": blockTypeSym<null>(),
        "minecraft:resource_or_tag": blockTypeSym<{registry: string}>(),
        "minecraft:resource_or_tag_key": blockTypeSym<{registry: string}>(),
        "minecraft:resource_selector": blockTypeSym<null>(),
        "minecraft:rotation": blockTypeSym<null>(),
        "minecraft:score_holder": blockTypeSym<{amount: "single" | "multiple"}>(),
        "minecraft:scoreboard_slot": blockTypeSym<null>(),
        "minecraft:style": blockTypeSym<null>(),
        "minecraft:swizzle": blockTypeSym<null>(),
        "minecraft:team": blockTypeSym<null>(),
        "minecraft:template_mirror": blockTypeSym<null>(),
        "minecraft:template_rotation": blockTypeSym<null>(),
        "minecraft:time": blockTypeSym<null>(),
        "minecraft:uuid": blockTypeSym<null>(),
        "minecraft:vec2": blockTypeSym<null>(),
        "minecraft:vec3": blockTypeSym<null>(),
    },
};
const demo: Block = {
    offset: 0,
    lines: [
        blockLine(basic.noop, null, [], blockType(basic.void, null)),
    ],
    validate: Symbol(),
};
*/