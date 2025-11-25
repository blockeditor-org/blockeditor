import { assert, throwErr, type AnalysisBlock, type ComptimeNarrowKey, type ComptimeType, type ComptimeValueAst, type Destructure, type DestructureExtract, type Env, type NsFields } from "./cmpyl";
import { colors, type SyntaxNode, type TokenPosition } from "./cvl2";

export function comptimeEval(env: Env, block: AnalysisBlock): unknown[] {
    const adisp = new Adisp();
    adisp.depth = 1;
    adisp.putBlock(block);
    console.log(adisp.end());

    const results = Array.from({length: block.lines.length}, () => undefined) as unknown[];
    for (let i = 0; i < block.lines.length; i += 1) {
        const instr = block.lines[i]!;
        if (instr.expr === "void") {
            results[i] = undefined;
        } else if (instr.expr === "comptime:only") {
            results[i] = undefined;
        } else if (instr.expr === "comptime:ast") {
            results[i] = instr.narrow satisfies ComptimeValueAst;
        } else if (instr.expr === "comptime:key") {
            results[i] = instr.narrow satisfies ComptimeNarrowKey;
        } else if (instr.expr === "comptime:ns_list_init") {
            results[i] = {
                locked: false,
                registered: new Map(),
            } satisfies NsFields;
        } else if (instr.expr === "comptime:ns_list_append") {
            const fields = (results[instr.list]! as NsFields);
            assert(!fields.locked);
            const key = results[instr.key] as ComptimeNarrowKey;
            const prevdef = fields.registered.get(key.key);
            const ast = results[instr.value] as ComptimeValueAst;
            if (prevdef) {
                throwErr(env, ast.pos, "already declared", [
                    [prevdef.ast.pos, "previous definition here"],
                ]);
            }
            fields.registered.set(key.key, {key, ast});

            results[i] = undefined;
        } else {
            throw new Error("todo: comptime eval expr: "+instr.expr);
        }
    }
    return results;
}

type PrintCfg = {indent: string};
export class Adisp {
    cfg: PrintCfg;
    indentCount: number = 0;
    depth: number;
    res: string[] = [];
    constructor(depth = Infinity) {
        this.cfg = {indent: "│ "};
        this.depth = depth;
    }
    end(): string {
        return this.res.join("");
    }

    indent() {
        this.indentCount += 1;
        return {[Symbol.dispose]: () => this.indentCount -= 1};
    }

    put(msg: string, color?: string): void {
        if (color) this.res.push(color);
        this.res.push(msg);
        if (color) this.res.push(colors.reset);
    }
    putNewline(): void {
        this.put("\n");
        this.put(this.cfg.indent.repeat(this.indentCount), colors.black);
    }
    putSrc(pos: TokenPosition) {
        this.put(` · ${pos.fyl}:${pos.lyn}:${pos.col}`, colors.black);
    }

    putCheckDepth() {
        if (this.indentCount > this.depth) {
            this.putNewline();
            this.put("...");
            return true;
        }
        return false;
    }

    putBlock(block: AnalysisBlock) {
        if (this.putCheckDepth()) return;
        for (let i = 0; i < block.lines.length; i++) {
            const expr = block.lines[i]!;
            let desc: string;
            if (i !== 0) this.putNewline();
            this.put(`${i} = `);
            this.put(expr.expr, colors.magenta);
            if (expr.expr === "call") {
                this.put(` method=${expr.method} arg=${expr.arg}`);
                this.putSrc(expr.pos);
            }else if(expr.expr === "comptime:only") {
                this.putSrc(expr.pos);
            }else if(expr.expr === "comptime:ns_list_init") {
                this.putSrc(expr.pos);
            }else if(expr.expr === "comptime:key") {
                if(expr.narrow.type === "string") {
                    this.put(` str=${JSON.stringify(expr.narrow.key)}`);
                    this.putSrc(expr.pos);
                }else{
                    this.put(` str=${JSON.stringify(expr.narrow.key.description??"(unnamed)")}, type=`);
                    this.putSrc(expr.pos);
                    using _1 = this.indent();
                    this.putType(expr.narrow.child);
                }
            }else if(expr.expr === "comptime:ast") {
                this.put(" ast:");
                this.putSrc(expr.pos);
                this.putAstList(expr.narrow.ast);
            }else if(expr.expr === "comptime:ns_list_append") {
                this.put(` key=${expr.key} list=${expr.list} value=${expr.value}`);
                this.putSrc(expr.pos);
            } else {
                this.put(" %%TODO%%");
                this.putSrc(expr.pos);
            }
        }
    }
    putType(type: ComptimeType) {
        if (this.putCheckDepth()) return;
        this.putNewline();
        this.put(type.type, colors.yellow);
        if (type.type === "fn") {
            this.putSrc(type.pos);
            using _ = this.indent();
            this.putNewline();
            this.put("arg=");
            {
                using _ = this.indent();
                this.putType(type.arg);
            }
            this.putNewline();
            this.put("ret=");
            {
                using _ = this.indent();
                this.putType(type.ret);
            }
        }else if(type.type === "void") {
            this.putSrc(type.pos);
        }else if(type.type === "folder_or_file") {
            this.putSrc(type.pos);
        }else {
            this.put(" %%TODO%%");
            this.putSrc(type.pos);
        }
    }
    putAstList(ast: SyntaxNode[]) {
        using _ = this.indent();
        if (this.putCheckDepth()) return;
        for (const node of ast) {
            this.putAstNode(node);
        }
        if (ast.length === 0) {
            this.putNewline();
            this.put("*no children*", colors.black);
        }
    }
    putAstNode(entity: SyntaxNode) {
        this.putNewline();
        this.put(entity.kind, colors.cyan);

        if (entity.kind === "block") {
            this.put(` ${entity.tag}`);
            this.putSrc(entity.pos);
            this.putAstList(entity.items);
        } else if(entity.kind === "binary") {
            this.put(` ${entity.tag}`);
            this.putSrc(entity.pos);
            this.putAstList(entity.items);
        } else if(entity.kind === "op") {
            this.put(` ${JSON.stringify(entity.op)}`, colors.yellow);
            this.putSrc(entity.pos);
        } else if(entity.kind === "opSeg") {
            this.putSrc(entity.pos);
            this.putAstList(entity.items);
        } else if(entity.kind === "ws") {
            this.put(` ${JSON.stringify(entity.nl ? "\n" : " ")}`);
            this.putSrc(entity.pos);
        } else if(entity.kind === "ident") {
            const jstr = JSON.stringify(entity.str);
            this.put(` ${entity.identTag}`);
            this.put(` ${(jstr.match(/^"[a-zA-Z_][a-zA-Z0-9_]*"$/) ?  jstr.slice(1, -1) : "#" + jstr)}`, colors.blue);
            this.putSrc(entity.pos);
        } else if(entity.kind === "strSeg") {
            this.put(` ${JSON.stringify(entity.str)}`, colors.green);
            this.putSrc(entity.pos);
        } else if(entity.kind === "raw") {
            this.put(` ${entity.tag}`);
            this.putSrc(entity.pos);
        } else {
            this.put(` %%TODO%%`);
            this.putSrc(entity.pos);
        }
    }
    putDestructure(destructure: Destructure) {
        if (this.putCheckDepth()) return;
        this.putNewline();
        this.put("extract=");
        {
            using _ = this.indent();
            this.putDestructureExtract(destructure.extract);
        }
        this.putNewline();
        this.put("type=");
        {
            using _ = this.indent();
            this.putType(destructure.type);
        }
    }
    putDestructureExtract(extract: DestructureExtract) {
        this.putNewline();
        this.put(extract.kind, colors.cyan);
        if (extract.kind === "single_item") {
            this.put(` ${JSON.stringify(extract.name)}`, colors.green);
            this.putSrc(extract.pos);
        } else if (extract.kind === "list") {
            this.putSrc(extract.pos);
            using _ = this.indent();
            for (const child of extract.items) {
                this.putDestructureExtract(child);
            }
        } else {
            this.put(` %%TODO%%`);
            this.putSrc(extract.pos);
        }
    }

    putSingle<T>(printer: AdispSingleItemPrinter<T>, value: NoInfer<T>) {

    }
    putList<T>(printer: AdispSingleItemPrinter<T>, value: NoInfer<T>[]) {

    }
    static dump<T>(printer: AdispSingleItemPrinter<T>, value: NoInfer<T>, depth: number = Infinity): string {
        const res = new Adisp(depth);
        res.putSingle(printer, value);
        return res.end();
    }
    static dumpAst(ast: SyntaxNode[], depth: number = Infinity): string {
        const res = new Adisp(depth);
        res.putAstList(ast);
        return res.end();
    }
    static dumpDestructure(destructure: Destructure, depth: number = Infinity): string {
        const res = new Adisp(depth);
        {
            using _ = res.indent();
            res.putDestructure(destructure);
        }
        return res.end();
    }
}

export type AdispSingleItemPrinter<T> = (adisp: Adisp, item: T) => void;
export const adisp_types = {} satisfies Record<string, AdispSingleItemPrinter<unknown>>;
