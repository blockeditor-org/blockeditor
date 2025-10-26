function unreachable(): never {
    throw new Error("unreachable");
}

type TokenizerMode = "regular" | "in_string";
type Config = {
    style: "open" | "close" | "join",
    prec: number,
    close?: string,
    autoOpen?: boolean,
    setMode?: TokenizerMode,
    joinTag?: string,
};

const mkconfig: Record<string, Omit<Config, "prec">>[] = [
    {
        "(": {style: "open", close: ")"},
        "{": {style: "open", close: "}"},
        "[": {style: "open", close: "]"},
        ")": {style: "close"},
        "}": {style: "close"},
        "]": {style: "close"},
    },
    {
        ",": {style: "join", joinTag: "sep"},
        ";": {style: "join", joinTag: "sep"},
        "\n": {style: "join", joinTag: "sep"},
    },
    {
        "::": {style: "join", joinTag: "bind"},
    },
    {
        "=>": {style: "join"},
    },
    {
        ":": {style: "open"},
    },
    {
        "=": {style: "join", joinTag: "assign"},
    },
    {
        ".": {style: "close", autoOpen: true},
    },
    {
        "\"": {style: "open", close: "<in_string>\"", setMode: "in_string"},
        "<in_string>\"": {style: "close", setMode: "regular"},
    },

    // TODO: "=>"
    // TODO: "\()" as style open prec 0 autoclose display{open: "(", close: ")"}
];

const config: Record<string, Config> = {};
for(const [i, segment] of mkconfig.entries()) {
    for(const [key, value] of Object.entries(segment)) {
        config[key] = {...value, prec: i};
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

interface TokenPosition {
    fyl: string;
    idx: number;
    lyn: number;
    col: number;
}

interface IdentifierToken {
    kind: "ident";
    pos: TokenPosition;
    str: string;
}

interface WhitespaceToken {
    kind: "ws";
    pos: TokenPosition;
    nl: boolean;
}

interface OperatorToken {
    kind: "op";
    pos: TokenPosition;
    op: string;
}

interface OperatorSegmentToken {
    kind: "opSeg";
    pos: TokenPosition;
    items: SyntaxNode[],
}

interface BlockToken {
    kind: "block";
    pos: TokenPosition;
    start: string;
    end: string;
    items: SyntaxNode[];
}

interface BinaryExpressionToken {
    kind: "binary";
    pos: TokenPosition;
    prec: number;
    tag: string;
    items: SyntaxNode[];
}

interface StrSegToken {
    kind: "strSeg";
    pos: TokenPosition;
    str: string;
}

type SyntaxNode = IdentifierToken | WhitespaceToken | OperatorToken | BlockToken | BinaryExpressionToken | OperatorSegmentToken | StrSegToken;

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

type TokenizationErrorEntry = {
    pos?: TokenPosition,
    style: "note" | "error",
    message: string,
};
type TokenizationError = {
    entries: TokenizationErrorEntry[],
    trace: TokenPosition[],
};
interface TokenizationResult {
    result: SyntaxNode[];
    errors: TokenizationError[];
}

const identifierRegex = /^[a-zA-Z0-9]$/;
const whitespaceRegex = /^\s$/;
const operatorChars = [..."~!@#$%^&*-=+|/<>:"];

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

            while (parseStack.length > 1) {
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

            if(currentToken === "\n") {
                nextVal.push({
                    kind: "ws",
                    pos: { fyl: source.filename, idx: start.idx, lyn: start.lyn, col: start.col },
                    nl: true,
                });
            }
        }else if(currentToken === " ") {
            currentSyntaxNodes.push({
                kind: "ws",
                pos: { fyl: source.filename, idx: start.idx, lyn: start.lyn, col: start.col },
                nl: false,
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

interface RenderConfig {
    indent: string;
    style?: "adisp";
}

function renderEntityList(config: RenderConfig, entities: SyntaxNode[], level: number, isTopLevel: boolean): string {
    let result = "";
    let needsDeeperIndent = false;
    let didInsertNewline = false;
    let lastNewlineIndex = -1;

    entities = entities.flatMap(nt => nt.kind === "opSeg" ? nt.items : [nt]); // hacky

    for (let i = 0; i < entities.length; i++) {
        const entity = entities[i]!;
        if (entity.kind === "ws" && entity.nl) {
            lastNewlineIndex = i;
        }
    }

    for (let i = 0; i < entities.length; i++) {
        const entity = entities[i]!;
        if (entity.kind === "ws") {
            if (entity.nl && !didInsertNewline) {
                needsDeeperIndent = !isTopLevel && i < lastNewlineIndex;
                didInsertNewline = true;
                result += "\n" + config.indent.repeat(level + (needsDeeperIndent ? 1 : 0));
            } else {
                result += " ";
            }
        } else {
            didInsertNewline = false;
            result += renderEntity(config, entity, level + (needsDeeperIndent ? 1 : 0), isTopLevel);
        }
    }
    return result;
}

function renderEntityJ(entity: SyntaxNode): unknown {
    const kind = `${entity.kind}:${entity.pos.lyn}:${entity.pos.col}`;
    if(entity.kind === "block") {
        return {
            kind,
            start: entity.start,
            end: entity.end,
            items: entity.items.map(renderEntityJ),
        };
    }else if(entity.kind === "binary") {
        return {
            kind,
            prec: entity.prec,
            items: entity.items.map(renderEntityJ),
        };
    }else if(entity.kind === "ws") {
        return {
            kind: kind,
            nl: entity.nl,
        }
    }else if(entity.kind === "op") {
        return {
            kind,
            op: entity.op,
        }
    }else if(entity.kind === "opSeg") {
        return {
            kind,
            items: entity.items.map(renderEntityJ),
        };
    }else if(entity.kind === "strSeg") {
        return {
            kind,
            str: entity.str,
        };
    }else if(entity.kind === "ident") {
        return {
            kind,
            str: entity.str,
        }
    }else return {
        kind,
        TODO: true,
    };
}
function renderEntity(config: RenderConfig, entity: SyntaxNode, level: number, isTopLevel: boolean): string {
    if(config.style === "adisp") {
        const ch: SyntaxNode[] | undefined = entity.kind === "block" || entity.kind === "binary" || entity.kind === "opSeg"  ? entity.items : undefined;
        let desc: string;
        if (entity.kind === "block") {
            desc = `${entity.start}${entity.end}`;
        } else if(entity.kind === "binary") {
            desc = ``;
        } else if(entity.kind === "op") {
            desc = `${colors.gold}${JSON.stringify(entity.op)}${colors.reset}`;
        } else if(entity.kind === "opSeg") {
            desc = ``;
        } else if(entity.kind === "ws") {
            desc = JSON.stringify(entity.nl ? "\n" : " ");
        } else if(entity.kind === "ident") {
            desc = colors.blue + JSON.stringify(entity.str) + colors.reset;
        } else if(entity.kind === "strSeg") {
            desc = colors.green + JSON.stringify(entity.str) + colors.reset;
        } else {
            desc = `%%TODO%%`;
        }
        return `${colors.cyan}${entity.kind}${colors.reset}${desc ? " " + desc : ""} ${colors.black}· ${entity.pos.fyl}:${entity.pos.lyn}:${entity.pos.col}${colors.reset}` + (ch ?? []).map(e => "\n" + colors.black + config.indent.repeat(level + 1) + colors.reset + renderEntity(config, e, level + 1, false)).join("");
    } else {
        if (entity.kind === "block") {
            return entity.start + renderEntityList(config, entity.items, level, false) + entity.end;
        } else if (entity.kind === "binary") {
            return renderEntityList(config, entity.items, level, isTopLevel);
        } else if (entity.kind === "ws") {
            throw new Error("Unreachable: Whitespace should be handled by renderEntityList.");
        } else if (entity.kind === "ident") {
            return entity.str;
        } else if (entity.kind === "op") {
            if(entity.op === "\n") return "";
            return entity.op;
        }else if (entity.kind === "opSeg") {
            throw new Error("Unreachable: opSeg should be handled by renderEntityList.");
        }else if (entity.kind === "strSeg") {
            return entity.str;
        } else {
            return `%TODO<${(entity as {kind: string}).kind}>%`;
        }
    }
}

const colors = {
    red: "\x1b[31m",
    gold: "\x1b[33m",
    green: "\x1b[32m",
    brgreen: "\x1b[92m",
    blue: "\x1b[34m",
    cyan: "\x1b[36m",
    black: "\x1b[30m",
    bold: "\x1b[1m",
    reset: "\x1b[0m",
};

function prettyPrintErrors(source: Source, errors: TokenizationError[]): string {
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
    const formattedCode = renderEntityList({ indent: "  " }, tokenizationResult.result, 0, true);
    const adisp = renderEntityList({indent: "│ ", style: "adisp"}, tokenizationResult.result, 0, true);
    const jsonCode = JSON.stringify(tokenizationResult.result.map(renderEntityJ), null, 1);
    const prettyErrors = prettyPrintErrors(source, tokenizationResult.errors);
    
    return (
        `// json:\n${jsonCode}\n\n` +
        `// adisp:\n${adisp}\n\n` +
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