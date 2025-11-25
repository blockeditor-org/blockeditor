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
                    this.putSingle(printers.type, expr.narrow.child);
                }
            }else if(expr.expr === "comptime:ast") {
                this.put(" ast:");
                this.putSrc(expr.pos);
                this.putList(printers.astNode, expr.narrow.ast);
            }else if(expr.expr === "comptime:ns_list_append") {
                this.put(` key=${expr.key} list=${expr.list} value=${expr.value}`);
                this.putSrc(expr.pos);
            } else {
                this.put(" %%TODO%%");
                this.putSrc(expr.pos);
            }
        }
    }

    putSingle<T>(printer: SinglePrinter<T>, value: NoInfer<T>) {
        if (this.putCheckDepth()) return;
        printer.single(this, value);
    }
    putMulti<T>(printer: MultiPrinter<T>, value: NoInfer<T>) {
        using _ = this.indent();
        if (this.putCheckDepth()) return;
        printer.multi(this, value);
    }
    putList<T>(printer: SinglePrinter<T>, children: NoInfer<T>[]) {
        using _ = this.indent();
        if (this.putCheckDepth()) return;
        for (const child of children) {
            this.putNewline();
            this.putSingle(printer, child);
        }
        if (children.length === 0) {
            this.putNewline();
            this.put("*no children*", colors.black);
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
        {
            using _ = res.indent();
            res.putNewline();
            res.putSingle(this, value);
        }
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
    destructure: new MultiPrinter<Destructure>((adisp, destructure) => {
        adisp.putNewline();
        adisp.put("extract=");
        {
            using _ = adisp.indent();
            adisp.putNewline();
            adisp.putSingle(printers.destructureExact, destructure.extract);
        }
        adisp.putNewline();
        adisp.put("type=");
        {
            using _ = adisp.indent();
            adisp.putSingle(printers.type, destructure.type);
        }
    }),
    destructureExact: new SinglePrinter<DestructureExtract>((adisp, extract) => {
        adisp.put(extract.kind, colors.cyan);
        if (extract.kind === "single_item") {
            adisp.put(` ${JSON.stringify(extract.name)}`, colors.green);
            adisp.putSrc(extract.pos);
        } else if (extract.kind === "list") {
            adisp.putSrc(extract.pos);
            using _ = adisp.indent();
            for (const child of extract.items) {
                adisp.putSingle(printers.destructureExact, child);
            }
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
            {
                using _ = adisp.indent();
                adisp.putSingle(printers.type, type.arg);
            }
            adisp.putNewline();
            adisp.put("ret=");
            {
                using _ = adisp.indent();
                adisp.putSingle(printers.type, type.ret);
            }
        }else if(type.type === "void") {
            adisp.putSrc(type.pos);
        }else if(type.type === "folder_or_file") {
            adisp.putSrc(type.pos);
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

