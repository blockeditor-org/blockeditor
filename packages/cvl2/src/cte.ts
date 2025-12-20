import { assert, compileFunction, createDeclaration, throwErr, type AnalysisBlock, type ComptimeValue, type Env, type NsFields, type RuntimeValue } from "./cmpyl";
import { type TokenPosition } from "./cvl2";
import { printers } from "./printers";

type RuntimeData = {block: AnalysisBlock, results: (ComptimeValue | undefined)[]};
type VK<K extends ComptimeValue["kind"]> = Extract<ComptimeValue, {kind: NoInfer<K>}>;
export function getComptime<K extends ComptimeValue["kind"]>(env: Env, k: K | null, v: RuntimeValue, pos: TokenPosition, runtime?: RuntimeData): VK<K> {
    if (v.kind === "runtime") {
        if (!runtime) assert(false, env, pos, `Value must be known at comptime.`);
        if (v.validate !== runtime.block.validate) {
            throwErr(env, pos, `Assertion failure: Ex`)
        }
        const q = runtime.results[v.idx]!;
        return getComptime<K>(env, k, q, pos);
    } else if (k == null || v.kind === k) {
        return v as unknown as Extract<ComptimeValue, {kind: NoInfer<K>}>;
    } else {
        assert(false, env, pos, `Expected value of type ${JSON.stringify(k)}, got ${JSON.stringify(v.kind)}`);
    }
};

export function comptimeEval(env: Env, block: AnalysisBlock, result: RuntimeValue, pos: TokenPosition, args: RuntimeValue | null = null): ComptimeValue {
    console.log("comptimeEval" + printers.block.dump(block, 2));

    const getas = <K extends ComptimeValue["kind"]>(k: K | null, v: RuntimeValue, pos: TokenPosition): VK<K> => getComptime(env, k, v, pos, rt);

    const results = Array.from({length: block.lines.length}, () => undefined) as (ComptimeValue | undefined)[];
    const rt: RuntimeData = {block, results};
    for (let i = 0; i < block.lines.length; i += 1) {
        const instr = block.lines[i]!;
        if (instr.expr === "comptime:ns_list_init") {
            results[i] = {
                kind: "ns_fields",
                locked: false,
                registered: new Map(),
            } satisfies NsFields;
        } else if (instr.expr === "comptime:ns_list_append") {
            const fields = getas("ns_fields", instr.list, instr.pos);
            assert(!fields.locked, env, instr.pos);
            const key = getas("key", instr.key, instr.pos);
            const prevdef = fields.registered.get(key.key);
            const ast = getas("ast", instr.value, instr.pos);
            if (prevdef) {
                throwErr(env, ast.pos, "already declared", [
                    [prevdef.decl.ast.pos, "previous definition here"],
                ]);
            }
            fields.registered.set(key.key, {key, decl: createDeclaration(env, ast)});

            results[i] = undefined;
        } else if (instr.expr === "call") {
            const method = getas("fn", instr.method, instr.pos);
            const arg = getas(null, instr.arg, instr.pos);
            const body = compileFunction(env, method);
            results[i] = comptimeEval(env, body.block, body.value, instr.pos, arg);
        } else if (instr.expr === "args") {
            if (args == null) throwErr(env, instr.pos, "cannot get args when executing without args", [
                [pos, "called here"],
            ], "unreachable");
            results[i] = getas(null, args, instr.pos);
        } else {
            throwErr(env, instr.pos, "todo: comptime eval expr: "+instr.expr);
        }
    }
    return getas(null, result, pos);
}
