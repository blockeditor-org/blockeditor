function unreachable(): never {
    throw new Error("unreachable");
}

type TokenizerMode = "regular" | "in_string";
type Config = {
    style: "open" | "close" | "join",
    prec: number,
    precStr: PrecString,
    close?: string,
    autoOpen?: boolean,
    setMode?: TokenizerMode,
    joinTag?: string,
};

const mkconfig = {
    paren: {
        "(": {style: "open", close: ")"},
        "{": {style: "open", close: "}"},
        "[": {style: "open", close: "]"},
        ")": {style: "close"},
        "}": {style: "close"},
        "]": {style: "close"},
    },
    sep: {
        ",": {style: "join", joinTag: "sep"},
        ";": {style: "join", joinTag: "sep"},
        "\n": {style: "join", joinTag: "sep"},
    },
    bind: {
        // name :: value (pub name = value)
        "::": {style: "join", joinTag: "def"},
        // .name .= value (def name = value)
        ".=": {style: "join", joinTag: "pub"},
        ":=": {style: "join", joinTag: "pub"},
    },
    right_associative: {
        ":": {style: "open"},
        "=>": {style: "open"},
    },
    equals: {
        "=": {style: "join", joinTag: "assign"},
    },
    string: {
        "\"": {style: "open", close: "<in_string>\"", setMode: "in_string"},
        "<in_string>\"": {style: "close", setMode: "regular"},
    },

    // TODO: "=>"
    // TODO: "\()" as style open prec 0 autoclose display{open: "(", close: ")"}
} satisfies Record<string, Record<string, Omit<Config, "prec" | "precStr">>>;
export type PrecString = keyof typeof mkconfig;

const config: Record<string, Config> = {};
{
    let i = 0;
    for(const [name, segment] of Object.entries(mkconfig)) {
        for(const [key, value] of Object.entries(segment)) {
            config[key] = {...value, prec: i, precStr: name};
        }
        i += 1;
    }
}

const referenceTrace: TokenPosition[] = [];
function withReferenceTrace(pos: TokenPosition): {[Symbol.dispose]: () => void} {
    referenceTrace.push(pos);
    return {[Symbol.dispose]() {
        const popped = referenceTrace.pop();
        if(popped !== pos) unreachable();
    }};
}

export class Source {
    public text: string;
    public currentIndex: number;
    public currentLine: number;
    public currentCol: number;
    public filename: string;
    public currentLineIndentLevel: number;

    constructor(filename: string, text: string) {
        this.text = text;
        this.currentIndex = 0;
        this.currentLine = 1;
        this.currentCol = 1;
        this.filename = filename;
        this.currentLineIndentLevel = this.calculateIndent();
    }

    peek(): string {
        return this.text[this.currentIndex] ?? "";
    }

    take(): string {
        const character = this.peek();
        this.currentIndex += character.length;

        if (character === "\n") {
            this.currentLine += 1;
            this.currentCol = 1;
            this.currentLineIndentLevel = this.calculateIndent();
        } else {
            this.currentCol += character.length;
        }
        return character;
    }

    private calculateIndent(): number {
        const subString = this.text.substring(this.currentIndex);
        const indentMatch = subString.match(/^ */);
        return indentMatch ? indentMatch[0].length : 0;
    }

    getPosition(): TokenPosition {
        return {
            fyl: this.filename,
            idx: this.currentIndex,
            lyn: this.currentLine,
            col: this.currentCol,
        }
    }
}

export interface TokenPosition {
    fyl: string;
    idx: number;
    lyn: number;
    col: number;
}

export interface IdentifierToken {
    kind: "ident";
    pos: TokenPosition;
    str: string;
}

export interface BuiltinToken {
    kind: "builtin";
    pos: TokenPosition;
    str: string;
}

export interface WhitespaceToken {
    kind: "ws";
    pos: TokenPosition;
    nl: boolean;
}

export interface OperatorToken {
    kind: "op";
    pos: TokenPosition;
    op: string;
}

export interface OperatorSegmentToken {
    kind: "opSeg";
    pos: TokenPosition;
    items: SyntaxNode[],
}

export interface BlockToken {
    kind: "block";
    pos: TokenPosition;
    start: string;
    end: string;
    items: SyntaxNode[];
    precStr: PrecString;
}

export interface BinaryExpressionToken {
    kind: "binary";
    pos: TokenPosition;
    prec: number;
    precStr: PrecString;
    tag: string;
    items: SyntaxNode[];
}

export interface StrSegToken {
    kind: "strSeg";
    pos: TokenPosition;
    str: string;
}

export interface RawToken {
    kind: "raw";
    pos: TokenPosition;
    raw: string;
}

export interface ErrToken {
    kind: "err";
    pos: TokenPosition;
}

export type SyntaxNode = IdentifierToken | BuiltinToken | WhitespaceToken | OperatorToken | BlockToken | BinaryExpressionToken | OperatorSegmentToken | StrSegToken | RawToken | ErrToken;

interface TokenizerStackItem {
    pos: TokenPosition,
    char: string;
    indent: number;
    val: SyntaxNode[];
    opSupVal?: SyntaxNode[];
    prec: number;
    autoClose?: boolean;
    tag?: string;
}

export type TokenizationErrorEntry = {
    pos?: TokenPosition,
    style: "note" | "error",
    message: string,
};
export type TokenizationError = {
    entries: TokenizationErrorEntry[],
    trace: TokenPosition[],
};
export interface TokenizationResult {
    result: SyntaxNode[];
    errors: TokenizationError[];
}

const identifierRegex = /^[a-zA-Z0-9]$/;
const whitespaceRegex = /^\s$/;
const operatorChars = [..."~!@$%^&*-=+|/<>:"];

export function tokenize(source: Source): TokenizationResult {
    let currentSyntaxNodes: SyntaxNode[] = [];
    const errors: TokenizationError[] = [];
    const parseStack: TokenizerStackItem[] = [];
    let mode: TokenizerMode = "regular";

    parseStack.push({ pos: source.getPosition(), char: "", indent: -1, val: currentSyntaxNodes, prec: 0 });

    while (source.peek()) {
        const start = source.getPosition();
        const firstChar = source.take();
        
        let currentToken: string;
        if(mode === "regular") {
            if (firstChar.match(identifierRegex)) {
                while (source.peek().match(identifierRegex)) {
                    source.take();
                }
                currentSyntaxNodes.push({
                    kind: "ident",
                    pos: { fyl: source.filename, idx: start.idx, lyn: start.lyn, col: start.col },
                    str: source.text.substring(start.idx, source.currentIndex),
                });
                continue;
            }
            if (firstChar === "#") {
                source.take();
                
                while (source.peek().match(identifierRegex)) {
                    source.take();
                }
                currentSyntaxNodes.push({
                    kind: "builtin",
                    pos: { fyl: source.filename, idx: start.idx, lyn: start.lyn, col: start.col },
                    str: source.text.substring(start.idx + 1, source.currentIndex),
                });
                continue;
            }

            if (firstChar.match(whitespaceRegex)) {
                while (source.peek().match(whitespaceRegex)) {
                    source.take();
                }
                currentToken = source.text.substring(start.idx, source.currentIndex).includes("\n") ? "\n" : " ";
            }else if ("()[]{},;\"'.`".includes(firstChar)) {
                currentToken = source.text.substring(start.idx, source.currentIndex);
            }else if(operatorChars.includes(firstChar)) {
                while (operatorChars.includes(source.peek())) {
                    source.take();
                }
                currentToken = source.text.substring(start.idx, source.currentIndex);
            }else if(firstChar === "\\") {
                // todo: if '\()' token = '\()'
                currentToken = "\\";
            }else{
                currentToken = firstChar;
            }
        }else if(mode === "in_string") {
            if ((!"\"\\".includes(firstChar))) {
                while (!"\"\\".includes(source.peek())) {
                    source.take();
                }
                currentSyntaxNodes.push({
                    kind: "strSeg",
                    pos: { fyl: source.filename, idx: start.idx, lyn: start.lyn, col: start.col },
                    str: source.text.substring(start.idx, source.currentIndex),
                });
                continue;
            }

            if(firstChar === "\"") {
                currentToken = "<in_string>\"";
            }else if(firstChar === "\\") {
                throw new Error("TODO impl in_string '\\' char");
            }else currentToken = firstChar;
        }else throw new Error("TODO mode: "+mode);

        const cfg = config[currentToken];
        if(cfg?.setMode) mode = cfg.setMode;
        if (cfg?.style === "open") {
            const newBlockItems: SyntaxNode[] = [];
            currentSyntaxNodes.push({
                kind: "block",
                pos: { fyl: source.filename, idx: start.idx, lyn: start.lyn, col: start.col },
                start: currentToken,
                end: cfg.close ?? "",
                items: newBlockItems,
                precStr: cfg.precStr,
            });
            parseStack.push({
                pos: start,
                char: cfg.close ?? "",
                indent: source.currentLineIndentLevel,
                val: newBlockItems,
                prec: cfg.prec,
                autoClose: cfg.close == null,
            });
            currentSyntaxNodes = newBlockItems;
        } else if (cfg?.style === "close") {
            const currentIndent = source.currentLineIndentLevel;

            while (parseStack.length > 0) {
                const lastStackItem = parseStack.pop();
                if (!lastStackItem) unreachable();

                if (lastStackItem.char === currentToken && lastStackItem.indent === currentIndent) {
                    currentSyntaxNodes = parseStack[parseStack.length - 1]!.val;
                    break;
                }

                if (lastStackItem.indent < currentIndent || lastStackItem.prec < cfg.prec) {
                    parseStack.push(lastStackItem);
                    if(cfg.autoOpen) {
                        // right, we have to worry about operators
                        let firstNonWs = 0;
                        while(firstNonWs < lastStackItem.val.length) {
                            if(lastStackItem.val[firstNonWs]?.kind !== "ws") break;
                            firstNonWs += 1;
                        }
                        const prevItems = lastStackItem.val.splice(firstNonWs, lastStackItem.val.length - firstNonWs);
                        lastStackItem.val.push({
                            kind: "block",
                            pos: start,
                            start: "",
                            end: currentToken,
                            items: prevItems,
                            precStr: cfg.precStr,
                        });
                    }else{
                        errors.push({
                            entries: [{
                                message: "extra close bracket",
                                style: "error",
                                pos: start,
                            }],
                            trace: [...referenceTrace],
                        });
                    }
                    break;
                } else {
                    if (!lastStackItem.autoClose) {
                        errors.push({
                            entries: [{
                                message: "open bracket missing close bracket",
                                style: "error",
                                pos: lastStackItem.pos,
                            }, {
                                message: `expected ${JSON.stringify(lastStackItem.char)} indent '${lastStackItem.indent}', got ${JSON.stringify(currentToken)} indent '${currentIndent}'`,
                                style: "note",
                                pos: start,
                            }],
                            trace: [...referenceTrace],
                        });
                    }
                    currentSyntaxNodes = parseStack[parseStack.length - 1]!.val;
                }
            }
            if (parseStack.length === 0) throw new Error("ups parsestack len 0!");
        } else if (cfg?.style === "join") {
            const operatorPrecedence = cfg.prec;
            let targetCommaBlock: TokenizerStackItem | undefined;

            while (parseStack.length > 0) {
                const lastStackItem = parseStack[parseStack.length - 1]!;

                if (lastStackItem.prec === operatorPrecedence) {
                    if (lastStackItem.tag !== cfg.joinTag) {
                        errors.push({
                            entries: [{
                                message: "mixing operators disallowed",
                                style: "error",
                                pos: start,
                            }, {
                                message: "previous operator here",
                                style: "note",
                            }],
                            trace: [...referenceTrace],
                        });
                    }
                    targetCommaBlock = lastStackItem;
                    break;
                } else if (lastStackItem.prec < operatorPrecedence) {
                    let valStartIdx = 0;
                    const val = lastStackItem.val.slice(0);
                    const opSupVal: SyntaxNode[] = [
                        {
                            kind: "opSeg",
                            pos: start,
                            items: val,
                        },
                    ];
                    targetCommaBlock = {
                        pos: start,
                        char: currentToken,
                        val,
                        opSupVal,
                        indent: lastStackItem.indent,
                        autoClose: true,
                        prec: operatorPrecedence,
                        tag: cfg.joinTag ?? "",
                    };
                    parseStack.push(targetCommaBlock);
                    lastStackItem.val.splice(valStartIdx, lastStackItem.val.length, {
                        kind: "binary",
                        pos: start,
                        prec: operatorPrecedence,
                        precStr: cfg.precStr,
                        items: opSupVal,
                        tag: cfg.joinTag ?? "",
                    });
                    break;
                } else {
                    if (!lastStackItem.autoClose) {
                        errors.push({
                            entries: [{
                                message: "item is never closed.",
                                style: "error",
                                pos: lastStackItem.pos,
                            }, {
                                message: "automatically closed here.",
                                style: "note",
                                pos: start,
                            }],
                            trace: [...referenceTrace],
                        });
                    }
                    parseStack.pop();
                }
            }

            if (!targetCommaBlock) {
                throw new Error("Unreachable: No target block found for comma/semicolon.");
            }
            if (!targetCommaBlock.opSupVal) {
                throw new Error("Target block missing opSupVal? Is this reachable?");
            }


            const nextVal: SyntaxNode[] = [];

            targetCommaBlock.opSupVal!.push({
                kind: "op",
                pos: start,
                op: currentToken,
            }, {
                kind: "opSeg",
                pos: start,
                items: nextVal,
            });
            targetCommaBlock.val = nextVal;
            currentSyntaxNodes = targetCommaBlock.val;
        }else if(currentToken === " ") {
            currentSyntaxNodes.push({
                kind: "ws",
                pos: { fyl: source.filename, idx: start.idx, lyn: start.lyn, col: start.col },
                nl: false,
            });
        }else if(currentToken === "." || currentToken == "->" || currentToken === "_") {
            currentSyntaxNodes.push({
                kind: "raw",
                pos: { fyl: source.filename, idx: start.idx, lyn: start.lyn, col: start.col },
                raw: currentToken,
            });
        } else {
            errors.push({
                entries: [{
                    message: "bad token "+JSON.stringify(currentToken),
                    style: "error",
                    pos: start,
                }],
                trace: [...referenceTrace],
            });
        }
    }

    return { result: parseStack[0]!.val, errors };
}

interface RenderConfigAdisp {
    indent: string;
}


export function renderEntityAdisp(config: RenderConfigAdisp, entity: SyntaxNode, level: number): string {
    const ch: SyntaxNode[] | undefined = entity.kind === "block" || entity.kind === "binary" || entity.kind === "opSeg"  ? entity.items : undefined;
    let desc: string;
    if (entity.kind === "block") {
        desc = `${entity.precStr}`;
    } else if(entity.kind === "binary") {
        desc = `${entity.precStr}`;
    } else if(entity.kind === "op") {
        desc = `${colors.yellow}${JSON.stringify(entity.op)}${colors.reset}`;
    } else if(entity.kind === "opSeg") {
        desc = ``;
    } else if(entity.kind === "ws") {
        desc = JSON.stringify(entity.nl ? "\n" : " ");
    } else if(entity.kind === "ident") {
        const jstr = JSON.stringify(entity.str);
        desc = colors.blue + (jstr.match(/^"[a-zA-Z_][a-zA-Z0-9_]*"$/) ?  jstr.slice(1, -1) : "#" + jstr) + colors.reset;
    } else if(entity.kind === "builtin") {
        desc = colors.blue + "#" + entity.str + colors.reset;
    } else if(entity.kind === "strSeg") {
        desc = colors.green + JSON.stringify(entity.str) + colors.reset;
    } else if(entity.kind === "raw") {
        desc = JSON.stringify(entity.raw);
    } else {
        desc = `%%TODO%%`;
    }
    return `${colors.cyan}${entity.kind}${colors.reset}${desc ? " " + desc : ""} ${colors.black}· ${entity.pos.fyl}:${entity.pos.lyn}:${entity.pos.col}${colors.reset}` + (ch ?? []).map(e => "\n" + colors.black + config.indent.repeat(level + 1) + colors.reset + renderEntityAdisp(config, e, level + 1)).join("");
}


interface RenderConfig {
    indent: string;
    reveal: boolean,
}
function renderEntityPrettyList(config: RenderConfig, entities: SyntaxNode[], indent: number, depth: number, isTopLevel: boolean): string {
    let result = "";
    let needsDeeperIndent = false;
    let didInsertNewline = false;
    let lastNewlineIndex = -1;

    entities = entities.flatMap(nt => nt.kind === "opSeg" ? nt.items : [nt]); // hacky

    const isNl = (entity: SyntaxNode) => (entity.kind === "ws" && entity.nl) || (entity.kind === "op" && entity.op === "\n");
    for (let i = 0; i < entities.length; i++) {
        const entity = entities[i]!;
        if (isNl(entity)) {
            lastNewlineIndex = i;
        }
    }

    let revealColor = rainbow[depth % rainbow.length]!;
    if (config.reveal) result += revealColor + "<" + colors.reset;

    for (let i = 0; i < entities.length; i++) {
        const entity = entities[i]!;
        if (isNl(entity)) {
            if (!didInsertNewline) {
                needsDeeperIndent = !isTopLevel && i < lastNewlineIndex;
                didInsertNewline = true;
                result += "\n" + config.indent.repeat(indent + (needsDeeperIndent ? 1 : 0));
            } else {
                result += " ";
            }
        } else {
            didInsertNewline = false;
            result += renderEntityPretty(config, entity, indent + (needsDeeperIndent ? 1 : 0), depth + 1, isTopLevel);
        }
    }
    if (config.reveal) result += revealColor + ">" + colors.reset;
    return result;
}
function renderEntityPretty(config: RenderConfig, entity: SyntaxNode, indent: number, depth: number, isTopLevel: boolean): string {
    if (entity.kind === "block") {
        return entity.start + renderEntityPrettyList(config, entity.items, indent, depth, false) + entity.end.replaceAll("<in_string>", "");
    } else if (entity.kind === "binary") {
        return renderEntityPrettyList(config, entity.items, indent, depth, isTopLevel);
    } else if (entity.kind === "ws") {
        if(entity.nl) return "";
        return " ";
    } else if (entity.kind === "ident") {
        return entity.str;
    } else if (entity.kind === "builtin") {
        return "#" + entity.str;
    } else if (entity.kind === "op") {
        if(entity.op === "\n") return "";
        return entity.op;
    }else if (entity.kind === "opSeg") {
        throw new Error("Unreachable: opSeg should be handled by renderEntityList.");
    }else if (entity.kind === "strSeg") {
        return entity.str;
    }else if (entity.kind === "raw") {
        return entity.raw;
    } else {
        return `%TODO<${(entity as {kind: string}).kind}>%`;
    }
}

export const colors = {
    black: "\x1b[30m",
    red: "\x1b[31m",
    green: "\x1b[32m",
    yellow: "\x1b[33m",
    blue: "\x1b[34m",
    magenta: "\x1b[35m",
    cyan: "\x1b[36m",
    white: "\x1b[37m",

    brblack: "\x1b[90m",
    brred: "\x1b[91m",
    brgreen: "\x1b[92m",
    bryellow: "\x1b[93m",
    brblue: "\x1b[94m",
    brmagenta: "\x1b[95m",
    brcyan: "\x1b[96m",
    brwhite: "\x1b[97m",

    reset: "\x1b[0m",
    bold: "\x1b[1m",
    dim: "\x1b[2m",
    italic: "\x1b[3m",
    underline: "\x1b[4m",
    blink: "\x1b[5m",
    inverse: "\x1b[7m",
    hidden: "\x1b[8m",
    strikethrough: "\x1b[9m",
};
const styles = {
    string: colors.green,
};
const rainbow = [colors.red, colors.yellow, colors.green, colors.cyan, colors.blue, colors.magenta];

export function prettyPrintErrors(source: Source, errors: TokenizationError[]): string {
    if (errors.length === 0) return "";

    const sourceLines = source.text.split('\n');
    let output = "";

    for (const error of errors) {
        output += "\n";

        for (const entry of error.entries) {
            const { pos, style, message } = entry;
            const color = style === 'error' ? colors.red : colors.blue;
            const bold = style === 'error' ? colors.bold : "";

            output += `${pos?.fyl ?? "??"}:${pos?.lyn ?? "??"}:${pos?.col ?? "??"}: ${color}${bold}${style}${colors.reset}: ${message}${colors.reset}\n`;
            
            const line = pos?.fyl === source.filename ? sourceLines[pos.lyn - 1] : "";
            if (line === undefined) continue;

            const lineNumberStr = `${pos?.lyn ?? "??"}`;
            const gutterWidth = lineNumberStr.length;
            const emptyGutter = ` ${" ".repeat(gutterWidth)} ${colors.blue}|${colors.reset}`;
            const lineGutter = ` ${colors.cyan}${lineNumberStr}${colors.reset} ${colors.blue}|${colors.reset}`;

            output += `${lineGutter} ${line}\n`;

            const pointer = ' '.repeat((pos?.col ?? 1) - 1) + '^';
            output += `${emptyGutter} ${color}${colors.bold}${pointer}${colors.reset}\n`;
        }
        if (error.trace.length > 0) {
            for(const line of error.trace) {
                output += `At ${line.fyl}:${line.lyn}:${line.col}\n`;
            }
        }
    }

    return output;
}

export function renderTokenizedOutput(tokenizationResult: TokenizationResult, source: Source): string {
    const formattedCode = renderEntityPrettyList({ indent: "  ", reveal: false }, tokenizationResult.result, 0, 0, true);
    const uglyCode = renderEntityPrettyList({ indent: "  ", reveal: true }, tokenizationResult.result, 0, 0, true);
    const adisp = tokenizationResult.result.map(r => renderEntityAdisp({indent: "│ "}, r, 0)).join("\n");
    const prettyErrors = prettyPrintErrors(source, tokenizationResult.errors);
    
    return (
        `// adisp:\n${adisp}\n\n` +
        `// ugly\n${uglyCode}\n\n` +
        `// formatted\n${formattedCode}\n\n` +
        `// errors:\n${prettyErrors}`
    );
}
const src = `abc [
    def [jkl]
    if (
            amazing.one()
    ] else {
            wow!
    }
    demoFn(1, 2
        3
        4, 5, 6
    7, 8)
    commaExample(1, 2, 3, 4)
    colonExample(a: 1, b: c: 2, 3)
    newlineCommaExample(
        1, 2
        3
        4
    )
    (a, b => c, d = e, f => g, h)
] ghi`;
if (import.meta.main) {
    const sourceCode = new Source("src.qxc", src);

    const tokenized = tokenize(sourceCode);
    console.log(renderTokenizedOutput(tokenized, sourceCode));
}