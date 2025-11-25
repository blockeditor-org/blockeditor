import { assert, throwErr, type AnalysisBlock, type ComptimeNarrowKey, type ComptimeType, type ComptimeValueAst, type Destructure, type DestructureExtract, type Env, type NsFields } from "./cmpyl";
import { colors, type SyntaxNode, type TokenPosition } from "./cvl2";

export function comptimeEval(env: Env, block: AnalysisBlock): unknown[] {
    console.log(printers.block.dump(block, 2));

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

    putCheckDepth(n?: number) {
        if (this.indentCount > this.depth) {
            this.putNewline();
            this.put("...", colors.black);
            if (n != null && n > 0) this.put(` ${n} item${n === 1 ? "" : "s"}`, colors.black);
            return true;
        }
        return false;
    }

    putSingle<T>(printer: SinglePrinter<T>, value: NoInfer<T>) {
        using _ = this.indent();
        if (this.putCheckDepth()) return;
        this.putNewline();
        printer.single(this, value);
    }
    putMulti<T>(printer: MultiPrinter<T>, value: NoInfer<T>) {
        using _ = this.indent();
        if (this.putCheckDepth()) return;
        printer.multi(this, value);
    }
    putList<T>(printer: SinglePrinter<T>, children: NoInfer<T>[]) {
        using _ = this.indent();
        if (children.length === 0) {
            this.putNewline();
            this.put("*no children*", colors.black);
            return;
        }
        if (this.putCheckDepth(children.length)) return;
        for (const child of children) {
            this.putNewline();
            printer.single(this, child);
        }
    }
}

class SinglePrinter<T> {
    single: (adisp: Adisp, item: T) => void;
    constructor(printFn: (adisp: Adisp, item: T) => void) {
        this.single = printFn;
    }
    dump(value: T, depth: number = Infinity): string {
        const res = new Adisp(depth);
        res.putSingle(this, value);
        return res.end();
    }
    dumpList(value: T[], depth: number = Infinity): string {
        const res = new Adisp(depth);
        res.putList(this, value);
        return res.end();
    }
}
class MultiPrinter<T> {
    multi: (adisp: Adisp, item: T) => void;
    constructor(printFn: (adisp: Adisp, item: T) => void) {
        this.multi = printFn;
    }
    dump(value: T, depth: number = Infinity): string {
        const res = new Adisp(depth);
        res.putMulti(this, value);
        return res.end();
    }
}

export const printers = {
    block: new MultiPrinter<AnalysisBlock>((adisp, block) => {
        if (adisp.putCheckDepth()) return;
        for (let i = 0; i < block.lines.length; i++) {
            const expr = block.lines[i]!;
            adisp.putNewline();
            adisp.put(`${i} = `);
            adisp.put(expr.expr, colors.magenta);
            if (expr.expr === "call") {
                adisp.put(` method=${expr.method} arg=${expr.arg}`);
                adisp.putSrc(expr.pos);
            }else if(expr.expr === "comptime:only") {
                adisp.putSrc(expr.pos);
            }else if(expr.expr === "comptime:ns_list_init") {
                adisp.putSrc(expr.pos);
            }else if(expr.expr === "comptime:key") {
                if(expr.narrow.type === "string") {
                    adisp.put(` str=${JSON.stringify(expr.narrow.key)}`);
                    adisp.putSrc(expr.pos);
                }else{
                    adisp.put(` str=${JSON.stringify(expr.narrow.key.description??"(unnamed)")}, type=`);
                    adisp.putSrc(expr.pos);
                    adisp.putSingle(printers.type, expr.narrow.child);
                }
            }else if(expr.expr === "comptime:ast") {
                adisp.put(" ast:");
                adisp.putSrc(expr.pos);
                adisp.putList(printers.astNode, expr.narrow.ast);
            }else if(expr.expr === "comptime:ns_list_append") {
                adisp.put(` key=${expr.key} list=${expr.list} value=${expr.value}`);
                adisp.putSrc(expr.pos);
            } else {
                adisp.put(" %%TODO%%");
                adisp.putSrc(expr.pos);
            }
        }
    }),
    destructure: new MultiPrinter<Destructure>((adisp, destructure) => {
        adisp.putNewline();
        adisp.put("extract=");
        adisp.putSingle(printers.destructureExact, destructure.extract);
        adisp.putNewline();
        adisp.put("type=");
        adisp.putSingle(printers.type, destructure.type);
    }),
    destructureExact: new SinglePrinter<DestructureExtract>((adisp, extract) => {
        adisp.put(extract.kind, colors.cyan);
        if (extract.kind === "single_item") {
            adisp.put(` ${JSON.stringify(extract.name)}`, colors.green);
            adisp.putSrc(extract.pos);
        } else if (extract.kind === "list") {
            adisp.putSrc(extract.pos);
            adisp.putList(printers.destructureExact, extract.items);
        } else {
            adisp.put(` %%TODO%%`);
            adisp.putSrc(extract.pos);
        }
    }),
    type: new SinglePrinter<ComptimeType>((adisp, type) => {
        adisp.put(type.type, colors.yellow);
        if (type.type === "fn") {
            adisp.putSrc(type.pos);
            using _ = adisp.indent();
            adisp.putNewline();
            adisp.put("arg=");
            adisp.putSingle(printers.type, type.arg);
            adisp.putNewline();
            adisp.put("ret=");
            adisp.putSingle(printers.type, type.ret);
        }else if(type.type === "void") {
            adisp.putSrc(type.pos);
        }else if(type.type === "folder_or_file") {
            adisp.putSrc(type.pos);
        }else if(type.type === "tuple") {
            adisp.putSrc(type.pos);
            adisp.putList(printers.type, type.children);
        }else {
            adisp.put(" %%TODO%%");
            adisp.putSrc(type.pos);
        }
    }),
    astNode: new SinglePrinter<SyntaxNode>((adisp, entity) => {
        adisp.put(entity.kind, colors.cyan);

        if (entity.kind === "block") {
            adisp.put(` ${entity.tag}`);
            adisp.putSrc(entity.pos);
            adisp.putList(printers.astNode, entity.items);
        } else if(entity.kind === "binary") {
            adisp.put(` ${entity.tag}`);
            adisp.putSrc(entity.pos);
            adisp.putList(printers.astNode, entity.items);
        } else if(entity.kind === "op") {
            adisp.put(` ${JSON.stringify(entity.op)}`, colors.yellow);
            adisp.putSrc(entity.pos);
        } else if(entity.kind === "opSeg") {
            adisp.putSrc(entity.pos);
            adisp.putList(printers.astNode, entity.items);
        } else if(entity.kind === "ws") {
            adisp.put(` ${JSON.stringify(entity.nl ? "\n" : " ")}`);
            adisp.putSrc(entity.pos);
        } else if(entity.kind === "ident") {
            const jstr = JSON.stringify(entity.str);
            adisp.put(` ${entity.identTag}`);
            adisp.put(` ${(jstr.match(/^"[a-zA-Z_][a-zA-Z0-9_]*"$/) ?  jstr.slice(1, -1) : "#" + jstr)}`, colors.blue);
            adisp.putSrc(entity.pos);
        } else if(entity.kind === "strSeg") {
            adisp.put(` ${JSON.stringify(entity.str)}`, colors.green);
            adisp.putSrc(entity.pos);
        } else if(entity.kind === "raw") {
            adisp.put(` ${entity.tag}`);
            adisp.putSrc(entity.pos);
        } else {
            adisp.put(` %%TODO%%`);
            adisp.putSrc(entity.pos);
        }
    }),
};

