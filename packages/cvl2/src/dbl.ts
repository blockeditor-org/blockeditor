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

type UserType = {link: string} | {intrinsic: string};
type UserDataFields = {
  [key: string]: UserType,
};
type UserData = {
  [key: string]: UserDataFields,
};
type UserQueryProvider = {arg: string} | "first" | "last" | {after: UserQueryProvider} | {before: UserQueryProvider};
type UserQuerySortProvider = "asc" | "dsc";
type UserBaseQuery = {
    args: string[],
    class: string,
  };
type UserGetQueries = {
  [key: string]: UserBaseQuery & {
    filter: {[key: string]: UserQueryProvider},
    sort: [string, UserQuerySortProvider][],
    get: string[],
  }
};
type UserInsertQueries = {
  [key: string]: UserBaseQuery & {
    insert: {[key: string]: UserQueryProvider},
  },
};
type User = {classes: UserData, get: UserGetQueries, insert: UserInsertQueries};
type ResolveDataFields = {

};
type ResolveType = {kind: "ref", class: string} | {kind: "u8"} | {kind: "order"};
type ResolveMappingValue = {
  class: string,
  field: string,
};
type ResolveMapping = {
  class: string,
  fromFields: string[],
  toFields: string[],
  sortField: string,
  sortMode: ResolveSortMode,
};
type ResolveSortMode = "none" | "appendOnly" | "appendPrepend" | "rbTree";
type Resolve = {
  mappings: ResolveMapping[],
};
type ResolveMappingCS = {
  class: string,
  sortField: string,
};
function csKey(cs: ResolveMappingCS): string {
  return JSON.stringify({
    class: cs.class,
    sortField: cs.sortField,
  });
}
function unionSortMode(a: ResolveSortMode, b: ResolveSortMode): ResolveSortMode {
  if (a === "none") return b;
  if (b === "none") return a;
  if (a === "appendOnly") return b;
  if (b === "appendOnly") return a;
  if (a === "appendPrepend") return b;
  if (b === "appendPrepend") return a;
  return "rbTree";
}
function exclam<T>(v: T | undefined): NoInfer<T> {
  if (!v) throw new Error("no exclam");
  return v;
}
function initDb(user: User) {
  const allMappings: ResolveMapping[] = [];
  const csToMapping = new Map<string, ResolveMapping[]>();
  function getCS(cs: ResolveMappingCS): ResolveMapping[] {
    const key = csKey(cs);
    const list = csToMapping.get(key) ?? [];
    csToMapping.set(key, list);
    return list;
  }
  function addMapping(m: ResolveMapping) {
    allMappings.push(m);
    getCS({class: m.class, sortField: m.sortField}).push(m);
  }

  for (const [name, value] of Object.entries(user.get)) {
    if (value.sort.length !== 1) throw new Error("todo (no or multi) sort");
    const mapping: ResolveMapping = {
      class: value.class,
      fromFields: Object.entries(value.filter).map(([k]) => k),
      toFields: [...value.get],
      sortField: value.sort[0]![0],
      sortMode: "none",
    };
    addMapping(mapping);
  }
  for (const [name, value] of Object.entries(user.insert)) {
    for (const [insk, insv] of Object.entries(value.insert)) {
      const cs = getCS({class: value.class, sortField: insk});
      const intrinsicSortMode: ResolveSortMode = insv === "last" ? "appendOnly" : insv === "first" ? "appendPrepend" : "rbTree";
      for (const mapping of cs) {
        mapping.sortMode = unionSortMode(mapping.sortMode, intrinsicSortMode);
      }
    }
  }

  console.log(allMappings);
  // which shouldn't be too hard to codegen into
  // Map<Text, ArrayList(u8)>
  // which we should be able to further optimize into
  // Text = struct {data: ArrayList(u8)}
}

function codegen(mappings: ResolveMapping[]) {
  let res: string[] = [];
  for (const mapping of mappings) {
    // - give the mapping a name
    // - generate the type, ie Map(Text.Handle, Sorted(struct {char: u8}))

    // fn Map(K, V) return AutoArrayHashMap(K, V)
    // fn Sorted(T) switch(order) { .append_only => MultiArrayList(T), .rb_tree => RbTree(T) }
  }
  // TODO: generate the insert & get functions
  return res.join("");
}

initDb({
  classes: {
    "Text": {},
    "Text.Character": {
      owner: {link: "Text"},
      char: {intrinsic: "u8"},
      order: {intrinsic: "Order"},
    },
  },
  get: {
    "Text.body": {args: ["text"], class: "Text.Character", filter: {owner: {arg: "text"}}, sort: [["order", "asc"]], get: ["char"]},
  },
  insert: {
    "Text.new": {args: [], class: "Text", insert: {}},
    "Text.push": {args: ["owner", "char"], class: "Text.Character", insert: {owner: {arg: "owner"}, char: {arg: "char"}, order: "last"}},
  },
});


/*
// what I would think is:
// - append only: arraylist
// - insert anywhere: red-black tree
// then, we wouldn't actually impl text like this. instead we would to Text { Segment { data: []u8, … } }
// but this is a nice demo

resolves to:
{
  Text: {
    Characters: ArrayList(u8)
    getAll() this.Characters.items
    create() new()
    push(char) this.Characters.append(char)
  },
}

the question is how do we do that resolution
- determine the scope of the order (global? local, to what?) based on sorts
  - if it's local then we should store the order in a Map<how to get here, the order>
- track the backreferences
- remove anything that isn't used

aka:
- character.order:
  - instances:
    - 0:
      - mode: (none, append, append_prepend, arbitrary) = .append
      - scope: Object[] = [Text]








*/