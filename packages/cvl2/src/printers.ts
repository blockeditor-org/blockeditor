import { type ComptimeValueFolderOrFile, type AnalysisBlock, type ComptimeType, type Destructure, type DestructureExtract, type RuntimeValue } from "./cmpyl";
import { colors, type SyntaxNode, type TokenPosition } from "./cvl2";

type PrintCfg = {indent: string};
export class Adisp {
    cfg: PrintCfg;
    indentCount: number = 0;
    depth: number;
    res: string[] = [];
    cache: Map<SinglePrinter<any> | MultiPrinter<any>, Map<unknown, number>> = new Map();
    referenceCount = 0;
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

    getOrAddCache(printer: SinglePrinter<any> | MultiPrinter<any>, value: unknown): number | undefined {
        if (!this.cache.has(printer)) this.cache.set(printer, new Map());
        const cache = this.cache.get(printer)!;
        if (cache.has(value)) return cache.get(value)!;
        cache.set(value, this.referenceCount++);
    }

    put(msg: string, color?: string): void {
        if (color) this.res.push(color);
        this.res.push(msg);
        if (color) this.res.push(colors.reset);
    }
    putWithNl(msg: string, color?: string): void {
        let i = 0;
        for(const seg of msg.split("\n")) {
            if (i++) this.putNewline();
            this.put(seg, color);
        }
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

    putInline<T>(printer: SinglePrinter<T>, value: NoInfer<T>) {
        const cached = this.getOrAddCache(printer, value);
        if (cached != null) {
            this.put(`[referenced value ${cached}]`);
        }
        printer.single(this, value);
    }
    putSingle<T>(printer: SinglePrinter<T>, value: NoInfer<T>) {
        using _ = this.indent();
        if (this.putCheckDepth()) return;
        this.putNewline();
        this.putInline(printer, value);
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
            this.putInline(printer, child);
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
                adisp.putSrc(expr.pos);
                using _ = adisp.indent();
                adisp.putNewline();
                adisp.put("method: ");
                adisp.putInline(printers.runtimeValue, expr.method);
                adisp.putNewline();
                adisp.put("arg: ");
                adisp.putInline(printers.runtimeValue, expr.arg);
            }else if(expr.expr === "comptime:ns_list_init") {
                adisp.putSrc(expr.pos);
            }else if(expr.expr === "comptime:ns_list_append") {
                adisp.putSrc(expr.pos);
                using _ = adisp.indent();
                adisp.putNewline();
                adisp.put("key: ");
                adisp.putInline(printers.runtimeValue, expr.key);
                adisp.putNewline();
                adisp.put("list: ");
                adisp.putInline(printers.runtimeValue, expr.list);
                adisp.putNewline();
                adisp.put("value: ");
                adisp.putInline(printers.runtimeValue, expr.value);
            } else {
                adisp.put(" %%TODO%%");
                adisp.putSrc(expr.pos);
            }
        }
    }),
    runtimeValue: new SinglePrinter<RuntimeValue>((adisp, rtv) => {
        adisp.put(rtv.kind, colors.green);
        if (rtv.kind === "key") {
            adisp.put(" " + rtv.type, colors.green);
            if (rtv.type === "string") {
                adisp.put(JSON.stringify(rtv.key));
            } else if (rtv.type === "symbol") {
                adisp.put(" " + rtv.key.toString());
                using _ = adisp.indent();
                adisp.putNewline();
                adisp.put("child: ");
                adisp.putInline(printers.type, rtv.child);
            } else {
                adisp.put(` %%TODO key kind%%`);
            }
        } else if (rtv.kind === "runtime") {
            adisp.put(` ${rtv.idx}`);
        } else if (rtv.kind === "ast") {
            adisp.putList(printers.astNode, rtv.ast);
        } else if (rtv.kind === "void") {
            // empty
        } else if (rtv.kind === "fn") {
            // todo
        } else {
            adisp.put(` %%TODO%%`);
        }
    }),
    destructure: new MultiPrinter<Destructure>((adisp, destructure) => {
        adisp.putNewline();
        adisp.put("extract: ");
        adisp.putInline(printers.destructureExact, destructure.extract);
        adisp.putNewline();
        adisp.put("type: ");
        adisp.putInline(printers.type, destructure.type);
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
            adisp.put("arg: ");
            adisp.putInline(printers.type, type.arg);
            adisp.putNewline();
            adisp.put("ret: ");
            adisp.putInline(printers.type, type.ret);
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
    folderOrFile: new SinglePrinter<ComptimeValueFolderOrFile>((adisp, entity) => {
        if (entity.value instanceof Uint8Array) {
            adisp.put("file", colors.blue);
            using _ = adisp.indent();
            adisp.putNewline();
            adisp.putWithNl(new TextDecoder().decode(entity.value), colors.green);
        } else {
            adisp.put("folder", colors.blue);
            using _ = adisp.indent();
            for (const [key, value] of Object.entries(entity.value)) {
                adisp.putNewline();
                adisp.put(JSON.stringify(key), colors.green);
                adisp.put(" = ");
                adisp.putInline(printers.folderOrFile, value);
            }
            if (Object.entries(entity.value).length === 0) {
                adisp.putNewline();
                adisp.put("*empty folder*", colors.black);
            }
        }
    }),
};

