// this works in iterm2, see https://gitlab.com/gnachman/iterm2/-/issues/11346
// ideally it would have an option to be collapsed by default

function fold(id: string, mode: "start" | "end"): string {
    return `\x1b]1337;Block=id=${id};attr=${mode}\x1b\\`;
}
let gid = 0;
function useGroup(): {[Symbol.dispose]: () => void} {
    const id = "" + (gid++);
    process.stdout.write(fold(id, "start"));
    return {[Symbol.dispose]: () => process.stdout.write(fold(id, "end"))};
}

console.log("line zero");
console.log("line one");
{
    using _ = useGroup();
    console.log("line three");
    console.log("line four");
    {
        using _2 = useGroup();
        console.log("line four.1");
        console.log("line four.2");
    }
}
console.log("line five");
console.log("line six");