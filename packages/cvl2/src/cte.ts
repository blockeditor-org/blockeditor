import { assert, throwErr, type AnalysisBlock, type ComptimeNarrowKey, type ComptimeType, type ComptimeValueAst, type Env, type NsFields } from "./cmpyl";
import { colors, renderEntityAdisp, type TokenPosition } from "./cvl2";

export function comptimeEval(env: Env, block: AnalysisBlock): unknown[] {
    console.log(printBlock({indent: "│ "}, block, 0));

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
function printBlock(cfg: PrintCfg, block: AnalysisBlock, indent: number): string {
    let res: string[] = [];
    for (let i = 0; i < block.lines.length; i++) {
        const expr = block.lines[i]!;
        let desc: string;
        if (expr.expr === "call") {
            desc = `method=${expr.method} arg=${expr.arg}`;
        }else if(expr.expr === "comptime:only") {
            desc = "";
        }else if(expr.expr === "comptime:ns_list_init") {
            desc = "";
        }else if(expr.expr === "comptime:key") {
            if(expr.narrow.type === "string") {
                desc = `str=${JSON.stringify(expr.narrow.key)}`;
            }else{
                desc = `symbol=${expr.narrow.key.description??"(unnamed)"}, type=${printType(cfg, expr.narrow.child, indent + 1)}`;
            }
        }else if(expr.expr === "comptime:ast") {
            desc = "ast:" + printSrc(expr.pos) +expr.narrow.ast.map(l => "\n"+printIndent(cfg, indent + 1)+renderEntityAdisp(cfg, l, indent + 1));
        }else if(expr.expr === "comptime:ns_list_append") {
            desc = `key=${expr.key} list=${expr.list} value=${expr.value}`;
        } else {
            desc = "%%TODO%%";
        }
        res.push(`${i} = ${colors.magenta}${expr.expr}${colors.reset}${desc ? " " + desc : ""}${printSrc(expr.pos)}`);
    }
    return res.join("\n" + printIndent(cfg, indent));
}
export function printIndent(cfg: PrintCfg, indent: number): string {
    return colors.black+cfg.indent.repeat(indent)+colors.reset;   
}
function printSrc(pos: TokenPosition): string {
    return ` ${colors.black}· ${pos.fyl}:${pos.lyn}:${pos.col}${colors.reset}`;
}
function printType(cfg: PrintCfg, type: ComptimeType, indent: number): string {
    let desc: string;
    if (type.type === "fn") {
        desc = `\n${printIndent(cfg, indent)}arg=${printType(cfg, type.arg, indent + 1)}\n${printIndent(cfg, indent)}ret=${printType(cfg, type.ret, indent + 1)}`;
    }else if(type.type === "void") {
        desc = "";
    }else if(type.type === "folder_or_file") {
        desc = "";
    }else {
        desc = "%%TODO%%";
    }
    return `${colors.yellow}${type.type}${colors.reset}${desc ? desc.startsWith("\n") ? ":" : " " + desc : ""}${printSrc(type.pos)}${desc && desc.startsWith("\n") ? desc : ""}`;
}

export class Adisp {
    cfg: PrintCfg;
    indent: number = 0;
    res: string[] = [];
    constructor() {
        this.cfg = {indent: "│ "};
    }
    end(): string {
        return this.res.join("");
    }

    put(msg: string): void {
        this.res.push(msg);
    }
    newline(): void {
        this.put(printIndent(this.cfg, this.indent));
    }
}