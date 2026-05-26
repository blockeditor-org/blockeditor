import { validateCName, type CValidatedIdentifierName } from "./backend/c";
import { addErr, analyze, analyzeBase, analyzeBlock, assert, blockAppend, castValue, compilerPos, createDeclaration, dec, emptyBlock, enc, getDeclaration, throwConsumedErr, throwErr, type AnalysisBlock, type AnalysisResult, type Binary2, type ComptimeFolder, type ComptimeValueBuildArtifact, type ComptimeValueDeclaration, type ComptimeValueExportList, type ConsumedErrorToken, type Env, type Uint8ArraySourcemapEntry } from "./cmpyl";
import { comptimeEval, getComptime } from "./cte";
import { unescapeString, type BlockToken, type IdentifierToken, type SyntaxNode, type TokenPosition } from "./cvl2";
import { printers } from "./printers";


const cache0arg = Symbol();
export class Type {
    static from<T extends new (...args: any) => any>(this: T, ...args: ConstructorParameters<NoInfer<T>>): InstanceType<NoInfer<T>> {
        if (args.length === 0 && (this as any)[cache0arg]) return (this as any)[cache0arg] as InstanceType<T>;
        const res = new this(...args);
        if (args.length === 0) (this as any)[cache0arg] = res;
        return res;
    }
    into(env: Env, block: AnalysisBlock, other: AnalysisResult, pos: TokenPosition): AnalysisResult {
        if (other.type === this) return other;
        throwErr(env, pos, `TODO implicit casting: ${this.dump()}`);
    }

    // TODO there should be two versions of this
    // fromString, fromStringAggrandizements
    // we should for fromString, it should accept uint8Array. for aggrandizements it should accept a list of (pos, uint8array) | Aggrandizement
    fromString(env: Env, slot: Type, ast: BlockToken, block: AnalysisBlock): AnalysisResult {
        throwErr(env, ast.pos, `String is not supported in slot: ${this.dump()}`);
    }
    // TODO: should not accept ast, should be simplified
    fromMap(env: Env, slot: Type, ast: BlockToken, block: AnalysisBlock): AnalysisResult {
        throwErr(env, ast.pos, `Map is not supported in slot: ${this.dump()}`);
    }
    // TODO: should accept uint8array or smth
    fromNumber(env: Env, slot: Type, ast: IdentifierToken, block: AnalysisBlock): AnalysisResult {
        throwErr(env, ast.pos, `Number is not supported in slot: ${this.dump()}`);
    }

    dump(): string {
        return `${Object.getPrototypeOf(this).constructor.name}`;
        // printers.type.dump(this, 3);
    }
    analyzeCall(env: Env, slot: Type, pos: TokenPosition, method: AnalysisResult, argIn: {pos: TokenPosition, ast: SyntaxNode[]}, block: AnalysisBlock): AnalysisResult {
        throwErr(env, pos, "not supported call type: " + this.dump());
    }
    analyzeAccess(env: Env, slot: Type, obj: AnalysisResult, pos: TokenPosition, prop: AnalysisResult, block: AnalysisBlock): AnalysisResult {
        throwErr(env, pos, "not supported access type: " + this.dump());
    }

    implicitArgRetForArrowFn(): {arg: Type, ret: Type} {
        return {arg: TypeUnknown.from(), ret: TypeUnknown.from()};
    }
}

export class TypeVoid extends Type {}
export class TypeUnknown extends Type {}
export class TypeFn extends Type {
    constructor(
        public data: {
            pos: TokenPosition,
            // these will need to be lazily resolved?
            arg: Type,
            ret: Type,
        },
    ) {super()}


    override analyzeCall(env: Env, slot: Type, pos: TokenPosition, method: AnalysisResult, argIn: {pos: TokenPosition, ast: SyntaxNode[]}, block: AnalysisBlock): AnalysisResult {
        const arg = analyze(env, this.data.arg, argIn.pos, argIn.ast, block);
        return {
            value: blockAppend(block, {expr: "call", method: method.value, arg: arg.value, pos}),
            type: this.data.ret,
        };
    }
}

export class TypeUint8Array extends Type {
    constructor() {super()}

    override fromString(env: Env, slot: Type, ast: BlockToken, block: AnalysisBlock): AnalysisResult {
        if (ast.items.length !== 1) throwErr(env, ast.pos, "TODO str items len != 1 todo" + printers.astNode.dumpList(ast.items, 3), [], "todo");
        const it0 = ast.items[0]!;
        if (it0.kind !== "raw" || it0.tag !== "string") throwErr(env, ast.pos, "TODO str item 0 ! raw string" + printers.astNode.dump(it0, 3));
        // if it has aggrandizements it might need runtime construction unless they're all comptime
        // although if it's a uint8array you can't runtime construct the aggrandizements so maybe it should just error
        const unescaped = unescapeString(env, it0.raw, it0.pos);
        const sourcemap: Uint8ArraySourcemapEntry[] = [];
        // TODO: fill out the sourcemap so that we can ask to make an error point to a specific byte of a comptime uint8array
        return {type: TypeUint8Array.from(), value: {kind: "uint8array", value: enc.encode(unescaped), sourcemap}};
    }
}

export class TypeTuple extends Type {
    constructor(public children: Type[]) {super()}
}
export class TypeOptional extends Type {
    constructor(public child: Type) {super()}
}


export class CtExportList extends Type {
    constructor(public key: Type) {super()}
    
    override fromMap(env: Env, slot: Type, ast: BlockToken, block: AnalysisBlock): AnalysisResult {
        const thiskey = this.key;
        const exportsBlock: AnalysisBlock = emptyBlock();
        const arrEntry = blockAppend(exportsBlock, {expr: "comptime:kv_list_init", pos: ast.pos});
        const {env: envInner} = analyzeBlock(env, slot, ast.pos, ast.items, exportsBlock, {
            analyzeBind(env: Env, [lhs, op, rhs]: Binary2, block: AnalysisBlock): AnalysisResult {
                const key = analyze(env, thiskey, lhs.pos, lhs.items, block);
                const value = analyze(env, CtAst.from(), rhs.pos, rhs.items, block);
                // insert an instruction to append the value to the children list
                // we could directly append here, but that would preclude `blk: [.a = 1, .b = 2, break :blk, .c = 3]` if we even want to support that
                const ret = blockAppend(block, {expr: "comptime:kv_list_append", pos: op.pos, list: arrEntry, key: key.value, value: value.value});
                return {type: TypeVoid.from(), value: ret};
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

        return {type: CtExportList.from(this.key), value: result};
    }

}
export class CtKey extends Type {}
export class CtAst extends Type {}
export class CtNamespace extends Type {
    override analyzeCall(env: Env, slot: Type, pos: TokenPosition, method: AnalysisResult, argIn: {pos: TokenPosition, ast: SyntaxNode[]}, block: AnalysisBlock): AnalysisResult {
        const val = getComptime(env, "namespace", method.value, pos);
        if (val.call == null) throwErr(env, pos, "this namespace does not support call", [
            [val.pos, "defined here"],
        ]);
        return val.call(env, slot, pos, argIn, block);
    }

    override analyzeAccess(env: Env, slot: Type, obj: AnalysisResult, pos: TokenPosition, prop: AnalysisResult, block: AnalysisBlock): AnalysisResult {
        if (obj.value.kind !== "namespace") throwErr(env, pos, `cannot access on namespace type with value kind ${obj.value.kind}`);
        const asKey = CtKey.from().into(env, block, prop, pos);
        const kval = getComptime(env, "key", asKey.value, pos);
        if (kval.type === "string") {
            return obj.value.getString(env, pos, kval.key, block);
        }else{
            throwErr(env, pos, "TODO return ?symbolChildType .some(T) or .none");
        }
    }
}
export class CtType extends Type {
    override analyzeCall(env: Env, slot: Type, pos: TokenPosition, method: AnalysisResult, argIn: {pos: TokenPosition, ast: SyntaxNode[]}, block: AnalysisBlock): AnalysisResult {
        const slotType = getComptime(env, "type", method.value, pos);
        const result = analyze(env, slotType.type, argIn.pos, argIn.ast, block);
        return castValue(slotType.type, result);
    }
}
export class CtBuildArtifact extends Type {
    constructor(public narrow?: "folder" | "file") {super()}

    override fromString(env: Env, slot: Type, ast: BlockToken, block: AnalysisBlock): AnalysisResult {
        const str = analyzeBase(env, TypeUint8Array.from(), ast, block);
        const res = blockAppend(block, {expr: "comptime:file_create", pos: ast.pos, value: str.value});
        return {type: CtBuildArtifact.from(), value: res};
    }
    
    override fromMap(env: Env, slot: Type, ast: BlockToken, block: AnalysisBlock): AnalysisResult {
        const exportsBlock: AnalysisBlock = emptyBlock();
        const arrEntry = blockAppend(exportsBlock, {expr: "comptime:kv_list_init", pos: ast.pos});
        const {env: envInner} = analyzeBlock(env, slot, ast.pos, ast.items, exportsBlock, {
            analyzeBind(env: Env, [lhs, op, rhs]: Binary2, block: AnalysisBlock): AnalysisResult {
                const key = analyze(env, TypeUint8Array.from(), lhs.pos, lhs.items, block);
                const value = analyze(env, CtAst.from(), rhs.pos, rhs.items, block);
                // insert an instruction to append the value to the children list
                // we could directly append here, but that would preclude `blk: [.a = 1, .b = 2, break :blk, .c = 3]` if we even want to support that
                const ret = blockAppend(block, {expr: "comptime:kv_list_append", pos: op.pos, list: arrEntry, key: key.value, value: value.value});
                return {type: TypeVoid.from(), value: ret};
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
        return {type: CtBuildArtifact.from("folder"), value: {kind: "build_artifact", value: result}};
    }
    
}

export class McResult extends Type {
    constructor(
        public narrow?: "i32" | "fail",
    ) {super()}

    override into(env: Env, block: AnalysisBlock, other: AnalysisResult, pos: TokenPosition): AnalysisResult {
        if (other.type === this) return other;
        if (!(other.type instanceof McResult)) throwErr(env, pos, "no implicit cast available");
        if (this.narrow != null && this.narrow !== other.type.narrow) throwErr(env, pos, "cannot widen");
        return other;
    }

    override fromNumber(env: Env, slot: Type, ast: IdentifierToken, block: AnalysisBlock): AnalysisResult {
        const parsed = +ast.str;
        if (("" + (parsed |0)) !== ast.str) throwErr(env, ast.pos, `invalid i32: expected '${"" + (parsed |0)}', got '${ast.str}'`);
        return {type: McResult.from("i32"), value: {kind: "mc:result", result: parsed}};
    }
}

export class McNbtRef extends Type {
    constructor(
        public narrow?: "string" | "i8" | "i16" | "i32" | "i64" | "f32" | "f64" | [McNbtRef] | Map<string, McNbtRef>,
    ) {super()}

    override fromString(env: Env, slot: Type, ast: BlockToken, block: AnalysisBlock): AnalysisResult {
        const str = analyzeBase(env, TypeUint8Array.from(), ast, block);
        const u8a = getComptime(env, "uint8array", str.value, ast.pos);
        const decoded = dec.decode(u8a.value);
        return {type: McNbtRef.from("string"), value: {kind: "mc:nbt_ref", type: "string", value: decoded}};
    }
}

export class McIdentifier extends Type {
    constructor(
        public category?: string,
    ) {super()}
    override fromString(env: Env, slot: Type, ast: BlockToken, block: AnalysisBlock): AnalysisResult {
        const str = analyzeBase(env, TypeUint8Array.from(), ast, block);
        const u8a = getComptime(env, "uint8array", str.value, ast.pos);
        const decoded = dec.decode(u8a.value);
        const match = decoded.match(/^(?:([-._a-z0-9]+):)?([-._a-z0-9/]+)$/);
        if (!match) throwErr(env, ast.pos, "invalid minecraft identifier name"); // todo point to the specific bad character
        const namespace = match[1] ?? "minecraft";
        const path = match[2]!;
        if (namespace === "..") throwErr(env, ast.pos, "invalid minecraft identifier name");

        return {type: McIdentifier.from(), value: {kind: "mc:identifier", namespace, path}};
    }
}


export class CExportName extends Type {
    override fromString(env: Env, slot: Type, ast: BlockToken, block: AnalysisBlock): AnalysisResult {
        const str = analyzeBase(env, TypeUint8Array.from(), ast, block);
        const u8a = getComptime(env, "uint8array", str.value, ast.pos);
        const decoded = dec.decode(u8a.value);
        if (!validateCName(decoded)) throwErr(env, ast.pos, "invalid c identifier name", [
            // TODO: "note: invalid character here", pointing to an item of the sourcemap of the uint8array
        ]);
        return {type: CExportName.from(), value: {kind: "c:export_name", value: decoded as CValidatedIdentifierName}};
    }
}

/*
because we have the destination target available in comptime env, our ideal is to not
need a ct system. ideally instead of blockAppend(), every append is per-target.

so does that work? if so, how?

first off, each target would have its own block type
^ this means each target needs its own comptimeeval
^ that is not ideal. we would prefer to reuse comptimeeval across targets

so maybe we have a shared block type. in that case, the issue we run into is:
- function call can't use blockAppend(call), it has to dispatch per-target
- each target will have its own instruction for function calling, eg mc:function_call
- and then we have the same issue
  - we don't really want to implement mc:function_call at comptime
- can we always know if something needs to be evaluated at comptime before it is?
  - if we could, then 
  - well no. we can't do that. because a :: getenv() needs to be able to get the runtime target

so the question is do we want comptemp?
- comptemp:
  - comptemp is that platforms can define custom instruction types, and
    platforms can define what final types & instructions they support
    - eg mc would not support i32, but it would support mc:Result
    - a conversion with weight 1 of i32 to mc:Result would exist
    - when we convert a regular block to a comptemp one, we pathfind from any unsupported types
      - so a i32 initialization becomes a mc:Result initialization
    - and we pathfind instructions, so add becomes mc:add
- non-comptemp:
  - we run into some trouble. (a :: 1 + 2) needs to evaluate to 3 at comptime. but with non-comptemp,
    the type i32 itself would be backed by switch(target). and since target is mc, it would be backed by mc:result,
    which doesn't work

so ig we need comptemp :/
*/
