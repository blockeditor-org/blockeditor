import { compilerPos, throwErr, type AnalysisBlock, type Env, type RuntimeValue } from "../cmpyl";
import { printers } from "../printers";

export function codegenMcfunction(env: Env, block: AnalysisBlock, value: RuntimeValue): string {
    console.log("codegenMcfunction.block", printers.block.dump(block));
    console.log("codegenMcfunction.value", printers.runtimeValue.dump(value));

    const lines: string[] = [];
    for (const line of block.lines) {
        if (line.expr === "args") {
            // nothing to do
        } else {
            throwErr(env, line.pos, "TODO codegenMcfunction line: " + printers.block.dump(block));
        }
    }
    if (value.kind === "mc:result") {
        lines.push("return " + value.result);
    } else {
        throwErr(env, compilerPos(), "TODO codegenMcfunction result: " + printers.runtimeValue.dump(value));
    }
    return lines.join("\n");
}