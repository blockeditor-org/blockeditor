import { renderTokenizedOutput, Source, tokenize } from "./cvl2";

const src = `
main :: (): std.Folder [
    "a.out" = std.File: "out"
]

other :: void, other::void;other::void
`;

function importFile(filename: string, contents: string) {
    const sourceCode = new Source(filename, contents);
    const tokenized = tokenize(sourceCode);
    console.log(renderTokenizedOutput(tokenized, sourceCode));
}

// we must know before analyzing if something will be executed at comptime or runtime
// std.Folder: [] <- we don't know that std.Folder needs to be comptime
// the alternative is always executing at comptime unless it's impossible
type Env = {
    comptimeEnv: {
    },
};

function analyzeContainer() {
    
}
function analyzeDeclOrExpression() {

}

if(import.meta.main) {
    importFile("src.qxc", src);
}