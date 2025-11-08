import { assert, throwErr, type AnalysisBlock, type ComptimeNarrowKey, type ComptimeType, type ComptimeValueAst, type Env, type NsFields } from "./cmpyl";
import { colors, renderEntityAdisp, type SyntaxNode, type TokenPosition } from "./cvl2";

export function comptimeEval(env: Env, block: AnalysisBlock): unknown[] {
    const adisp = new Adisp();
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
    indent: number = 0;
    depth: number = Infinity;
    res: string[] = [];
    constructor() {
        this.cfg = {indent: "│ "};
    }
    end(): string {
        return this.res.join("");
    }

    put(msg: string, color?: string): void {
        if (color) this.res.push(color);
        this.res.push(msg);
        if (color) this.res.push(colors.reset);
    }
    putNewline(): void {
        this.put("\n");
        this.put(this.cfg.indent.repeat(this.indent), colors.black);
    }
    putSrc(pos: TokenPosition) {
        this.put(` · ${pos.fyl}:${pos.lyn}:${pos.col}`, colors.black);
    }

    putCheckDepth() {
        if (this.indent > this.depth) {
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
                    this.indent += 1;
                    this.putNewline();
                    this.indent += 1;
                    this.putType(expr.narrow.child);
                    this.indent -= 1;
                    this.indent -= 1;
                }
            }else if(expr.expr === "comptime:ast") {
                this.put(" ast:");
                this.putSrc(expr.pos);
                this.indent += 1;
                this.putNewline();
                this.putAst(expr.narrow.ast);
                this.indent -= 1;
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
        this.put(type.type, colors.yellow);
        if (type.type === "fn") {
            this.putSrc(type.pos);
            this.putNewline();
            this.put("arg=");
            this.indent += 1;
            this.putType(type.arg);
            this.indent -= 1;
            this.putNewline();
            this.indent += 1;
            this.put("ret=");
            this.putType(type.ret);
            this.indent -= 1;
        }else if(type.type === "void") {
            this.putSrc(type.pos);
        }else if(type.type === "folder_or_file") {
            this.putSrc(type.pos);
        }else {
            this.put(" %%TODO%%");
            this.putSrc(type.pos);
        }
    }
    putAst(ast: SyntaxNode[]) {
        if (this.putCheckDepth()) return;
        for (const node of ast) {
            if (node !== ast[0]) this.putNewline();
            this.put(renderEntityAdisp(this.cfg, node, this.indent));
        }
    }

    static dumpAst(ast: SyntaxNode[], depth: number = 3): string {
        const res = new Adisp();
        res.indent = 1;
        res.depth = depth;
        res.putNewline();
        res.putAst(ast);
        return res.end();
    }
}