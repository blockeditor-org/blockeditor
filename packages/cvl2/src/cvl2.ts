import { assert, throwErr, type Env } from "./cmpyl";
import { printers } from "./printers";

function unreachable(): never {
    throw new Error("unreachable");
}

type TokenizerMode = "regular" | "in_string" | "inline_comment";
type Config = {
    style: "open" | "close" | "join",
    prec: number,
    precStr: string,
    close?: string,
    autoOpen?: boolean,
    opTag?: OpTag,
    bracketTag?: BracketTag,
};

export type OpTag = "sep" | "def" | "pub" | "var" | "assign" | "";
export type BracketTag = "map" | "list" | "code" | "colon_call" | "arrow_fn" | "string" | "inline_comment" | "";
export type RawTag = "return" | "discard" | "void" | "string" | "comment";
export type IdentifierTag = "normal" | "access" | "builtin" | "number";

const mkconfig: Record<string, Record<string, Omit<Config, "prec" | "precStr">>> = {
    paren: {
        "(": {style: "open", close: ")", bracketTag: "list"},
        "{": {style: "open", close: "}", bracketTag: "code"},
        "[": {style: "open", close: "]", bracketTag: "map"},
        ")": {style: "close", bracketTag: "list"},
        "}": {style: "close", bracketTag: "code"},
        "]": {style: "close", bracketTag: "map"},
        "\\(": {style: "open", close: ")", bracketTag: "list"},
    },
    sep: {
        ",": {style: "join", opTag: "sep"},
        ";": {style: "join", opTag: "sep"},
        "\n": {style: "join", opTag: "sep"},
    },
    bind: {
        // name :: value (pub name = value)
        "::": {style: "join", opTag: "def"},
        // .name .= value (def name = value)
        ".=": {style: "join", opTag: "pub"},
        ":=": {style: "join", opTag: "var"},
    },
    right_associative: {
        ":": {style: "open", bracketTag: "colon_call"},
        "=>": {style: "open", bracketTag: "arrow_fn"},
    },
    equals: {
        "=": {style: "join", opTag: "assign"},
    },
    string: {
        "\"": {style: "open", close: "<in_string>\"", bracketTag: "string"},
        "<in_string>\"": {style: "close", bracketTag: "string"},
        "//": {style: "open", bracketTag: "inline_comment"},
    },

    // TODO: "=>"
    // TODO: "\()" as style open prec 0 autoclose display{open: "(", close: ")"}
};
const setModes: Partial<Record<BracketTag, TokenizerMode>> = {
    string: "in_string",
    inline_comment: "inline_comment",
};
const rawconfig: Record<string, RawTag> = {
    "->": "return",
    "_": "discard",
};
const identtag: Record<string, IdentifierTag> = {
    ".": "access",
    "#": "builtin",
};

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

const referenceTrace: TraceEntry[] = [];
function withReferenceTrace(pos: TokenPosition, text: string): {[Symbol.dispose]: () => void} {
    const appended: TraceEntry = {pos, text};
    referenceTrace.push(appended);
    return {[Symbol.dispose]() {
        const popped = referenceTrace.pop();
        if(popped !== appended) unreachable();
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
    revert(pos: TokenPosition) {
        this.filename = pos.fyl;
        this.currentIndex = pos.idx;
        this.currentLine = pos.lyn;
        this.currentCol = pos.col;
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
    identTag: IdentifierTag;
    identTagRaw: string;
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
    opTag: OpTag;
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
    tag: BracketTag;
}

export interface BinaryExpressionToken {
    kind: "binary";
    pos: TokenPosition;
    prec: number;
    tag: OpTag;
    items: SyntaxNode[];
}

export interface RawToken {
    kind: "raw";
    pos: TokenPosition;
    raw: string;
    tag: RawTag;
}

export interface ErrToken {
    kind: "err";
    pos: TokenPosition;
}

export type SyntaxNode = IdentifierToken | WhitespaceToken | OperatorToken | BlockToken | BinaryExpressionToken | OperatorSegmentToken | RawToken | ErrToken;

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
    style: TokenizationErrorStyle,
    message: string,
};
export type TokenizationErrorStyle = "note" | "error" | "todo" | "unreachable" | "warning";
export type TraceEntry = {
    pos: TokenPosition,
    text: string,
};
export type TokenizationError = {
    entries: TokenizationErrorEntry[],
    trace: TraceEntry[],
};
export interface TokenizationResult {
    result: SyntaxNode[];
    errors: TokenizationError[];
}

const identifierRegex = /^[a-zA-Z0-9_]$/;
const whitespaceRegex = /^\s$/;
const operatorChars = [..."~!@$%^&*-=+|/<>:."];

export function tokenize(source: Source): TokenizationResult {
    let currentSyntaxNodes: SyntaxNode[] = [];
    const errors: TokenizationError[] = [];
    const parseStack: TokenizerStackItem[] = [];

    parseStack.push({ pos: source.getPosition(), char: "", indent: -1, val: currentSyntaxNodes, prec: 0 });

    while (source.peek()) {
        const start = source.getPosition();
        
        let currentToken: string;
        const mode: TokenizerMode = setModes[(parseStack[parseStack.length - 1]?.tag ?? "") as BracketTag] ?? "regular";
        if(mode === "regular") {
            const firstChar = source.take();
            if (firstChar.match(identifierRegex)) {
                while (source.peek().match(identifierRegex)) {
                    source.take();
                }
                currentSyntaxNodes.push({
                    kind: "ident",
                    pos: { fyl: source.filename, idx: start.idx, lyn: start.lyn, col: start.col },
                    str: source.text.substring(start.idx, source.currentIndex),
                    identTag: firstChar.match(/^\d/) ? "number" : "normal",
                    identTagRaw: "",
                });
                continue;
            }
            if (identtag[firstChar]) {
                const beforeAttempt = source.getPosition();
                
                while (source.peek().match(identifierRegex)) {
                    source.take();
                }
                const len = source.currentIndex - start.idx - 1;
                if (len > 0) {
                    currentSyntaxNodes.push({
                        kind: "ident",
                        pos: { fyl: source.filename, idx: start.idx, lyn: start.lyn, col: start.col },
                        str: source.text.substring(start.idx + 1, source.currentIndex),
                        identTag: identtag[firstChar]!,
                        identTagRaw: firstChar,
                    });
                    continue;
                } else {
                    // failed to match identtag; revert
                    source.revert(beforeAttempt);
                }
            }

            if (firstChar.match(whitespaceRegex)) {
                while (source.peek().match(whitespaceRegex)) {
                    source.take();
                }
                currentToken = source.text.substring(start.idx, source.currentIndex).includes("\n") ? "\n" : " ";
            }else if ("()[]{},;\"'`".includes(firstChar)) {
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
            let request: TokenPosition | null = null;
            while (true) {
                const peek = source.peek();
                if (peek === "\\") {
                    const revert = source.getPosition();
                    source.take();
                    const escFirst = source.peek();
                    if (escFirst === "\"" || escFirst === "\\") {
                        source.take();
                    } else if (escFirst === "(") {
                        source.take();
                        request = source.getPosition();
                        currentToken = "\\(";
                        source.revert(revert);
                        break;
                    }
                } else if (peek === "\"") {
                    const revert = source.getPosition();
                    source.take();
                    request = source.getPosition();
                    currentToken = "<in_string>\"";
                    source.revert(revert);
                    break;
                } else {
                    source.take();
                }
            }
            currentSyntaxNodes.push({
                kind: "raw",
                pos: { fyl: source.filename, idx: start.idx, lyn: start.lyn, col: start.col },
                raw: source.text.substring(start.idx, source.currentIndex),
                tag: "string",
            });
            if (request) {
                source.revert(request);
            } else {
                continue;
            }
        } else if (mode === "inline_comment") {
            let request: TokenPosition | null = null;
            while (true) {
                const peek = source.peek();
                if (peek === "\n") {
                    const revert = source.getPosition();
                    source.take();
                    request = source.getPosition();
                    currentToken = "\n";
                    source.revert(revert);
                    break;
                } else {
                    source.take();
                }
            }
            currentSyntaxNodes.push({
                kind: "raw",
                pos: { fyl: source.filename, idx: start.idx, lyn: start.lyn, col: start.col },
                raw: source.text.substring(start.idx, source.currentIndex),
                tag: "comment",
            });
            if (request) {
                source.revert(request);
            } else {
                continue;
            }
        }else throw new Error("TODO mode: "+mode);

        const cfg = config[currentToken];
        if (cfg?.style === "open") {
            const newBlockItems: SyntaxNode[] = [];
            currentSyntaxNodes.push({
                kind: "block",
                pos: { fyl: source.filename, idx: start.idx, lyn: start.lyn, col: start.col },
                start: currentToken,
                end: cfg.close ?? "",
                items: newBlockItems,
                tag: cfg.bracketTag ?? "",
            });
            parseStack.push({
                pos: start,
                char: cfg.close ?? "",
                indent: source.currentLineIndentLevel,
                val: newBlockItems,
                prec: cfg.prec,
                autoClose: cfg.close == null,
                tag: cfg.bracketTag,
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
                            tag: cfg.bracketTag ?? "",
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
                    if (lastStackItem.tag !== cfg.opTag) {
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
                        tag: cfg.opTag ?? "",
                    };
                    parseStack.push(targetCommaBlock);
                    lastStackItem.val.splice(valStartIdx, lastStackItem.val.length, {
                        kind: "binary",
                        pos: start,
                        prec: operatorPrecedence,
                        items: opSupVal,
                        tag: cfg.opTag ?? "",
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
                opTag: targetCommaBlock.tag as OpTag,
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
        }else if(Object.hasOwn(rawconfig, currentToken)) {
            currentSyntaxNodes.push({
                kind: "raw",
                pos: { fyl: source.filename, idx: start.idx, lyn: start.lyn, col: start.col },
                raw: currentToken,
                tag: rawconfig[currentToken]!,
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
function posAddCol(pos: TokenPosition, col: number): TokenPosition {
    return {fyl: pos.fyl, lyn: pos.lyn, col: pos.col + col, idx: pos.col + col};
}
function parseHexCodepoint(env: Env, inner: string, segmentPos: TokenPosition): string {
    const bad = inner.search(/[^A-Fa-f0-9]/);
    if (bad !== -1) throwErr(env, posAddCol(segmentPos, bad), "bad character in curly");
    const parsed = parseInt(inner, 16); // maybe ok after validating. otherwise it will ignore things
    if (parsed > 0x10FFFF) throwErr(env, segmentPos, "number out of range");
    return String.fromCodePoint(parsed);
}
export function unescapeString(env: Env, segment: string, segmentPos: TokenPosition): string {
    if (!segment.includes("\\")) return segment;
    // this could be updated to use appendErr rather than throwErr, and return an ErrorToken|string
    {
        const newlineIndex = segment.indexOf("\n");
        if (newlineIndex !== -1) {
            throwErr(env, posAddCol(segmentPos, newlineIndex), "newline is not allowed in escaped string", [], "unreachable");
        }
    }
    let result = "";
    let idx = 0;
    while (true) {
        let nextEscape = segment.indexOf("\\", idx);
        if (nextEscape === -1) nextEscape = segment.length;
        result += segment.slice(idx, nextEscape);
        idx = nextEscape;
        if (segment[idx] !== "\\") break;
        idx += 1;
        const def = unescapeDefs.get(segment[idx] ?? "");
        if (def) {
            result += def;
        } else if (segment[idx] === "x") {
            idx += 1;
            const inner = segment.slice(idx, idx + 2);
            result += parseHexCodepoint(env, inner, posAddCol(segmentPos, idx));
            idx += 2;
        } else if (segment[idx] === "u") {
            idx += 1;
            const ustart = idx;
            if (segment[idx] !== "{") throwErr(env, posAddCol(segmentPos, idx), `expected \\u{ABCD}`);
            idx += 1;
            const istart = idx;
            let iend = segment.indexOf("}", istart);
            if (iend === -1) throwErr(env, posAddCol(segmentPos, ustart), `missing close curly`, [
                [posAddCol(segmentPos, segment.length), "string ended here"],
            ]);
            idx += 1;
            const inner = segment.slice(istart, iend);
            result += parseHexCodepoint(env, inner, posAddCol(segmentPos, istart));
        } else {
            throwErr(env, posAddCol(segmentPos, idx), `unexpected escape in string: ${JSON.stringify(segment[idx] ?? "<eof>")}`);
        }
    }
    return result;
}
export function highlightString(config: RenderConfig, segment: string): string {
    if (!segment.includes("\\")) return hl(config, segment, highlights.string);
    let result = "";
    let idx = 0;
    while (true) {
        let nextEscape = segment.indexOf("\\", idx);
        if (nextEscape === -1) nextEscape = segment.length;
        result += hl(config, segment.slice(idx, nextEscape), highlights.string);
        idx = nextEscape;
        if (segment[idx] !== "\\") break;
        result += hl(config, segment[idx] ?? "", highlights.brackets);
        idx += 1;
        const def = unescapeDefs.get(segment[idx] ?? "");
        if (def) {
            result += hl(config, segment[idx] ?? "", def === segment[idx] ? highlights.string : highlights.number);
            idx += 1;
        } else if (segment[idx] === "x") {
            result += hl(config, segment[idx] ?? "", highlights.keyword);
            idx += 1;
            result += hl(config, segment[idx] ?? "", highlights.number);
            idx += 1;
            result += hl(config, segment[idx] ?? "", highlights.number);
        } else if (segment[idx] === "u") {
            result += hl(config, segment[idx] ?? "", highlights.keyword);
            idx += 1;
            // TODO: highlight <brackets>\<keyword>u<brackets>{<number>0000<brackets>}<string>
            // or <brackets>\<error>{ab!<reset>cdef
            // - find the first char which is not A-Fa-f0-9 and mark error up to there unless it's close bracket
        } else {
            result += hl(config, segment[idx] ?? "", highlights.error);
            idx += 1;
        }
    }
    return result;
}
// TODO: impl highlightString()
const unescapeDefs = new Map<string, string>(Object.entries({
    "n": "\n",
    "r": "\r",
    "\"": "\"",
    "'": "'",
}));

interface RenderConfigAdisp {
    indent: string;
}


interface RenderConfig {
    indent: string,
    reveal: boolean,
    highlight: boolean,
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
function hl(config: RenderConfig, str: string, hl: string) {
    return config.highlight && str.trim() ? `${hl}${str}${colors.reset}` : str;
}
function renderEntityPretty(config: RenderConfig, entity: SyntaxNode, indent: number, depth: number, isTopLevel: boolean): string {
    if (entity.kind === "block") {
        return hl(config, entity.start, bracketHighlights[entity.tag] ?? highlights.error) +
            renderEntityPrettyList(config, entity.items, indent, depth, false) +
            hl(config, entity.end.replaceAll("<in_string>", ""), bracketHighlights[entity.tag] ?? highlights.error);
    } else if (entity.kind === "binary") {
        return renderEntityPrettyList(config, entity.items, indent, depth, isTopLevel);
    } else if (entity.kind === "ws") {
        if(entity.nl) return "";
        return " ";
    } else if (entity.kind === "ident") {
        return hl(config, entity.identTagRaw, identPrefixHighlights[entity.identTag] ?? highlights.error)
            + hl(config, entity.str, identValueHighlights[entity.identTag] ?? highlights.error);
    } else if (entity.kind === "op") {
        if(entity.op === "\n") return "";
        return hl(config, entity.op, opHighlights[entity.opTag] ?? highlights.error);
    }else if (entity.kind === "opSeg") {
        throw new Error("Unreachable: opSeg should be handled by renderEntityList.");
    }else if (entity.kind === "raw") {
        if (entity.tag === "string" && config.highlight) return highlightString(config, entity.raw);
        return hl(config, entity.raw, rawHighlights[entity.tag] ?? highlights.error);
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
export const highlights = {
    string: colors.green,
    keyword: colors.blue,
    brackets: colors.brblack,
    operators: colors.brblack,
    builtin: colors.cyan,
    comment: colors.yellow,
    number: colors.magenta,
    error: colors.inverse + colors.red,
    ident: "",
};
const rawHighlights: Partial<Record<RawTag, string>> = {
    return: highlights.keyword,
    discard: highlights.keyword,
    string: highlights.string,
    comment: highlights.comment,
};
const opHighlights: Partial<Record<OpTag, string>> = {
    def: highlights.keyword,
    pub: highlights.keyword,
    assign: highlights.keyword,
    sep: highlights.operators,
    var: highlights.keyword,
};
const bracketHighlights: Partial<Record<BracketTag, string>> = {
    string: highlights.brackets,
    colon_call: highlights.operators,
    map: highlights.brackets,
    list: highlights.brackets,
    code: highlights.brackets,
    arrow_fn: highlights.keyword,
    inline_comment: highlights.brackets,
};
const identPrefixHighlights: Partial<Record<IdentifierTag, string>> = {
    access: highlights.operators,
    builtin: highlights.builtin,
};
const identValueHighlights: Partial<Record<IdentifierTag, string>> = {
    normal: highlights.ident,
    access: highlights.ident,
    builtin: highlights.builtin,
    number: highlights.number,
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
            const color = style === 'error' ? colors.red : style === "note" ? colors.cyan : style === "todo" ? colors.blue : style === "warning" ? colors.yellow : colors.brblack;
            const bold = style !== 'note' ? colors.bold : "";

            output += `${pos?.fyl ?? "??"}:${pos?.lyn ?? "??"}:${pos?.col ?? "??"}: ${color}${bold}${style}${colors.reset}: ${message}${colors.reset}\n`;
            
            const line = pos?.fyl === source.filename ? sourceLines[pos.lyn - 1] : "";
            if (line === undefined) continue;

            const lineNumberStr = `${pos?.lyn ?? "??"}`;
            const gutterWidth = lineNumberStr.length;
            const emptyGutter = ` ${" ".repeat(gutterWidth)} ${colors.blue}|${colors.reset}`;
            const lineGutter = ` ${colors.cyan}${lineNumberStr}${colors.reset} ${colors.blue}|${colors.reset}`;

            output += `${lineGutter} ${line}\n`;

            const pointer = ' '.repeat(Math.max((pos?.col ?? 1) - 1, 0)) + '^';
            output += `${emptyGutter} ${color}${colors.bold}${pointer}${colors.reset}\n`;
        }
        if (error.trace.length > 0) {
            for(const line of error.trace) {
                output += ` at ${line.pos.fyl}:${line.pos.lyn}:${line.pos.col} (${line.text})\n`;
            }
        }
    }

    return output;
}

export function renderTokenizedOutput(tokenizationResult: TokenizationResult, source: Source): string {
    const formattedCode = renderEntityPrettyList({ indent: "  ", reveal: false, highlight: true }, tokenizationResult.result, 0, 0, true);
    const uglyCode = renderEntityPrettyList({ indent: "  ", reveal: true, highlight: false }, tokenizationResult.result, 0, 0, true);
    const adisp = printers.astNode.dumpList(tokenizationResult.result);
    const prettyErrors = prettyPrintErrors(source, tokenizationResult.errors);
    
    return (
        `// adisp:${adisp}\n\n` +
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