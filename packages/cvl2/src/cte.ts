import type { AnalysisBlock } from "./cmpyl";
import { colors, renderEntityAdisp } from "./cvl2";

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
        }else if(expr.expr === "comptime:ast") {
            desc = "ast:"+expr.value.ast.map(l => "\n"+colors.black+cfg.indent.repeat(indent + 1)+colors.reset+renderEntityAdisp(cfg, l, indent));
        }else if(expr.expr === "comptime:ns_list_append") {
            desc = `key=${expr.key} list=${expr.list} value=${expr.value}`;
        } else {
            desc = "%%TODO%%";
        }
        res.push(`${i} = ${colors.magenta}${expr.expr}${colors.reset}${desc ? " " + desc : ""} ${colors.black}· ${expr.pos.fyl}:${expr.pos.lyn}:${expr.pos.col}${colors.reset}`);
    }
    return res.join("\n" + colors.black+cfg.indent.repeat(indent)+colors.reset);
}