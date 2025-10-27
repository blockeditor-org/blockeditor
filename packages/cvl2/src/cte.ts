import type { AnalysisBlock, ComptimeType } from "./cmpyl";
import { colors, renderEntityAdisp, type TokenPosition } from "./cvl2";

export function comptimeEval(block: AnalysisBlock): void {
    console.log(printBlock({indent: "│ "}, block, 0));
    throw new Error("todo: comptime eval block");
}

type PrintCfg = {indent: string};
function printBlock(cfg: PrintCfg, block: AnalysisBlock, indent: number): string {
    let res: string[] = [];
    for (let i = 0; i < block.lines.length; i++) {
        const expr = block.lines[i]!;
        let desc: string;
        if (expr.expr === "call") {
            desc = `method=${expr.method} arg=${expr.arg}`;
        }else if(expr.expr === "comptime:ns_list_init") {
            desc = "";
        }else if(expr.expr === "comptime:only") {
            desc = "";
        }else if(expr.expr === "comptime:key") {
            if(expr.narrow.type === "string") {
                desc = `str=${JSON.stringify(expr.narrow.string)}`;
            }else{
                desc = `symbol=${expr.narrow.symbol.description??"(unnamed)"}, type=${printType(cfg, expr.narrow.child, indent + 1)}`;
            }
        }else if(expr.expr === "comptime:ast") {
            desc = "ast:"+expr.value.ast.map(l => "\n"+printIndent(cfg, indent + 1)+renderEntityAdisp(cfg, l, indent + 1));
        }else if(expr.expr === "comptime:ns_list_append") {
            desc = `key=${expr.key} list=${expr.list} value=${expr.value}`;
        } else {
            desc = "%%TODO%%";
        }
        res.push(`${i} = ${colors.magenta}${expr.expr}${colors.reset}${desc ? " " + desc : ""}${printSrc(expr.pos)}`);
    }
    return res.join("\n" + printIndent(cfg, indent));
}
function printIndent(cfg: PrintCfg, indent: number): string {
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