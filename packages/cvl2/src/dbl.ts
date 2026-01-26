/*

tables:

Node :: [
  parent: Node
  name: Doc
]
NodeContent :: [
  parent: Node
  doc: Doc
]
Doc :: [

]
DocByte :: [
  char: u8
  order: Order
]



queries:

DocContent :: \doc DocByte.filter(db => db.doc == doc).sort(a, b => a.order - b.order).map(c => c.char)
NodeChildren :: \node Node.filter(n => n.parent == node).sort(a, b => a.name - b.name).map(c => )

*/


const types = {
    u8: Symbol("u8"),
    order: Symbol("order"),
    table: (n: string) => n,
};
const tables = {
    Doc: {},
    DocByte: {
        char: types.u8,
        order: types.order,
        parent: types.table("Doc"),
    },
};