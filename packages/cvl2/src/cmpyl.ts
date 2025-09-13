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

function analyzeContainer() {
    
}
function analyzeDeclOrExpression() {

}

if(import.meta.main) {
    importFile("src.qxc", src);
}