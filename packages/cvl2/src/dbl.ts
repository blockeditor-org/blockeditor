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

type UserType = string;
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
type ResolveType = {kind: "ref", class: string} | {kind: "u8"} | {kind: "Order"};
type ResolveClass = {
  fields: Map<string, ResolveType>,
};
type ResolveMapping = {
  class: string,
  fromFields: Set<string>,
  toFields: Set<string>,
  sortField: string,
  sortMode: ResolveSortMode,
};
type ResolveSortMode = "none" | "appendOnly" | "appendPrepend" | "tree";
type Resolve = {
  mappings: ResolveMapping[],
  classes: Map<string, ResolveClass>,
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
function amKey(am: ResolveMapping): string {
  return JSON.stringify({
    class: am.class,
    fromFields: [...am.fromFields].toSorted(),
    sortField: am.sortField,
  });
}
function unionSortMode(a: ResolveSortMode, b: ResolveSortMode): ResolveSortMode {
  if (a === "none") return b;
  if (b === "none") return a;
  if (a === "appendOnly") return b;
  if (b === "appendOnly") return a;
  if (a === "appendPrepend") return b;
  if (b === "appendPrepend") return a;
  return "tree";
}
function exclam<T>(v: T | undefined): NoInfer<T> {
  if (!v) throw new Error("no exclam");
  return v;
}
function initDb(user: User) {
  const allMappings: ResolveMapping[] = [];
  const amToMapping: Map<string, ResolveMapping> = new Map();
  const csToMapping = new Map<string, ResolveMapping[]>();
  function getCS(cs: ResolveMappingCS): ResolveMapping[] {
    const key = csKey(cs);
    const list = csToMapping.get(key) ?? [];
    csToMapping.set(key, list);
    return list;
  }
  function addMapping(m: ResolveMapping) {
    const am = amKey(m);
    const pm = amToMapping.get(am)!;
    if (pm) {
      // extend the mapping rather than adding a new one
      pm.sortMode = unionSortMode(pm.sortMode, m.sortMode);
      for (const toField of m.toFields) {
        pm.toFields.add(toField);
      }
      return;
    }
    amToMapping.set(am, m);
    allMappings.push(m);
    getCS({class: m.class, sortField: m.sortField}).push(m);
  }

  for (const [name, value] of Object.entries(user.get)) {
    if (value.sort.length !== 1) throw new Error("todo (no or multi) sort");
    addMapping({
      class: value.class,
      fromFields: new Set(Object.entries(value.filter).map(([k]) => k)),
      toFields: new Set(value.get),
      sortField: value.sort[0]![0],
      sortMode: "none",
    });
  }
  for (const [name, value] of Object.entries(user.insert)) {
    for (const [insk, insv] of Object.entries(value.insert)) {
      const cs = getCS({class: value.class, sortField: insk});
      const intrinsicSortMode: ResolveSortMode = insv === "last" ? "appendOnly" : insv === "first" ? "appendPrepend" : "tree";
      for (const mapping of cs) {
        mapping.sortMode = unionSortMode(mapping.sortMode, intrinsicSortMode);
      }
    }
  }

  const allClasses: Map<string, ResolveClass> = new Map();
  for (const [name, desc] of Object.entries(user.classes)) {
    const resolveClass: ResolveClass = {fields: new Map()};
    for (const [fieldName, userType] of Object.entries(desc)) {
      let resolveType: ResolveType;
      if (Object.hasOwn(user.classes, userType)) {
        resolveType = {kind: "ref", class: userType};
      } else if (userType === "u8") {
        resolveType = {kind: "u8"};
      } else if (userType === "Order") {
        resolveType = {kind: "Order"};
      } else throw new Error("unsupported user type? " + userType);
      resolveClass.fields.set(fieldName, resolveType);
    }
    allClasses.set(name, resolveClass);
  }

  // insert fns:
  // - find all the places the data needs to be copied to
  // - insert in all those places
  // update fns:
  // - find all the places the data needs to be updated
  // - update in all those places
  // get fns:
  // - find the place the data can be gotten from
  // - return the value

  codegen({
    mappings: allMappings,
    classes: allClasses,
  });
  // which shouldn't be too hard to codegen into
  // Map<Text, ArrayList(u8)>
  // which we should be able to further optimize into
  // Text = struct {data: ArrayList(u8)}
}

const codeSym = Symbol("code");
type Code = {__is_code: typeof codeSym};
function c(a: TemplateStringsArray, ...b: (Code | undefined)[]): Code {
  const result: Code[] = [];
  for (let i = 0; i < a.length; i += 1) {
    result.push(craw(a[i]!));
    if (b[i]) result.push(b[i]!);
  }
  return craw(result);
}
function crender(a: Code): string {
  const final: string[] = [];
  crendersub(final, a, 0);
  return final.join("");
}
function crendersub(out: string[], a: Code, indent: number): void {
  const au = cunwrap(a);
  if (typeof au === "string") {
    if (au === "\n") {
      out.push("\n" + " ".repeat(indent * 4));
    } else {
      out.push(au);
    }
  }else if (Array.isArray(au)) {
    for (const elem of au) crendersub(out, elem, indent);
  }else if ('indent' in au) {
    return crendersub(out, au.indent, indent + 1);
  } else throw new Error("crendersubtodo: " + au);
}
function cjoin(a: Code[], b: Code, prefixPostfix?: Code, postfix?: Code): Code {
  postfix ??= prefixPostfix;
  const result: Code[] = [];
  if (prefixPostfix && a.length > 0) result.push(prefixPostfix);
  for (let i = 0; i < a.length; i++) {
    if (i !== 0) result.push(b);
    result.push(a[i]!);
  }
  if (postfix && a.length > 0) result.push(postfix);
  return craw(result);
}
function cindent(a: Code | undefined): Code {
  if (!a) return craw([]);
  return craw({indent: a});
}
const cnl = c`\n`;
function cnljoin(a: Code[], postfix?: Code): Code {
  return cjoin(a.map(cindent), cindent(c`\n`), cindent(c`${postfix}\n`), c`${cindent(postfix)}\n`);
}
type CodeRaw = string | Code[] | {indent: Code};
function craw(a: CodeRaw): Code {
  if (Array.isArray(a) && a.length === 1) return a[0]!;
  return a as unknown as Code;
}
function cunwrap(a: Code): CodeRaw {
  return a as unknown as CodeRaw;
}


function zigString(value: string): Code {
  // not accurate but good enough for now
  return craw(JSON.stringify(value));
}
function zigIdent(typeClass: string): Code {
  // not accurate but good enough for now probably
  if (typeClass.match(/^[a-zA-Z_][a-zA-Z0-9_]*$/)) return craw(typeClass);
  return craw("@" + JSON.stringify(typeClass));
}
function codegenClassRef(ctx: CodegenCtx, typeClass: string): Code {
  return c`${zigIdent(typeClass)}.Handle`;
}

type CodegenCtx = {resolve: Resolve};
function codegenType(ctx: CodegenCtx, type: ResolveType): Code {
  if (type.kind === "Order") {
    throw new Error("order should never be realized");
  } else if (type.kind === "ref") {
    return codegenClassRef(ctx, type.class);
  } else if (type.kind === "u8") {
    return c`u8`;
  } else throw new Error("oops");
}
function codegenFieldsType(ctx: CodegenCtx, mappingClass: string, mappingFields: Set<string>): Code {
  const srcClass = ctx.resolve.classes.get(mappingClass)!;
  let fields: Code[] = [];
  for (const field of [...mappingFields].toSorted()) {
    const type = srcClass.fields.get(field)!;
    fields.push(c`${zigIdent(field)}: ${codegenType(ctx, type)},`);
  }
  return c`struct {${cnljoin(fields)}}`;
}
const sortModeMap: {[key in ResolveSortMode]: Code} = {
  none: c`.none`,
  appendOnly: c`.append_only`,
  appendPrepend: c`.append_prepend`,
  tree: c`.tree`,
};

function codegen(resolve: Resolve) {
  const ctx: CodegenCtx = {resolve};
  const lines: Code[] = [];
  let gid = 0;

  lines.push(c`const Db = @This();`);
  lines.push(c`const lib = @import("lib.zig");`);

  lines.push(c``, c`// Mappings`);
  for (let i = 0; i < resolve.mappings.length; i++) {
    const mapping = resolve.mappings[i]!;
    // - give the mapping a name
    const name = `mapping_${i}`;
    // - generate the type, ie Map(Text.Handle, Sorted(struct {char: u8}))
    const from = codegenFieldsType(ctx, mapping.class, mapping.fromFields);
    const to = codegenFieldsType(ctx, mapping.class, mapping.toFields);
    const sort = sortModeMap[mapping.sortMode];
    const type = c`Map(${sort}, ${from}, ${to})`;

    lines.push(c`${zigIdent(name)}: ${type},`);

    // fn Map(K, V) return AutoArrayHashMap(K, V)
    // fn Sorted(T) switch(order) { .append_only => MultiArrayList(T), .rb_tree => RbTree(T) }
  }

  lines.push(c``, c`// Handle Types`);
  // we don't actually want all of these. we want Text but not Text.Character
  for (const [className, classData] of resolve.classes) {
    lines.push(c`const ${zigIdent(className)} = Pool(32, 32, opaque{}, struct{});`);
  }

  /*
  insert and get functions
  fn @"Text.new"(db: *Db, args: struct {}) std.mem.Allocator.Error!Text.Handle {
    return db.Text_pool.add(.{}) catch return error.OutOfMemory; // not really sure if this is what we want
  }
  fn @"Text.push"(db: *Db, args: struct { owner: Text.Handle, char: u8 }) std.mem.Allocator.Error)@"Text.Character".Handle {
    try db.text_to_chars_map.insertLast(db.gpa, .{.owner = owner}, .{ .char = args.char });
    return {}; // Text.Character.Handle is void
  }
  fn @"Text.body"(db: *Db, args: struct {owner: Text.Handle}) TextToCharsMap.Iterator {
    return try db.text_to_chars_map.get(.{ .owner = owner });
  }
  */

  const lib = `
  pub const SortMode = enum { none, append_only, append_prepend, tree };
  pub fn Map(comptime sort: SortMode, comptime From: type, comptime To: type) type {
    return struct {
      const This = @This();
      const SortBacking = switch(sort) {
        .append_only => std.MultiArrayList(To),
        else => @compileError("TODO: Map: ." ++ @tagName(sort)),
      };
      backing: std.AutoArrayHashMap(From, SortBacking),
      valid: u64,
      
      pub const ToField = std.meta.FieldEnum(To);
      pub const Iterator = struct {
        valid: u64,
        backing: switch (sort) {
          .append_only => struct { slice: std.MultiArrayList(To).Slice, index: usize },
          else => @compileError("TODO: Map.Iterator: ." ++ @tagName(sort)),
        };

        /// if this returns an empty slice, it is the end.
        pub fn peek(self: *Iterator, map: *This, comptime field: ToField) []const @FieldType(To, @tagName(field)) {
          std.debug.assert(self.valid == map.valid);
          return switch (sort) {
            .append_only => self.backing.items(field)[self.backing.index..],
            else => @compileError("TODO: Map.Iterator.peek: ." ++ @tagName(sort)),
          }
        }
        pub fn eat(self: *Iterator, n: usize) void {
          std.debug.assert(self.valid == map.valid);
          switch (sort) {
            .append_only => {
              std.debug.assert(self.backing.index + n <= self.backing.items.len);
              self.backing.index += n;
            },
            else => @compileError("TODO: Map.Iterator.next: ." ++ @tagName(sort)),
          }
        }
      };

      fn markInvalid(this: *This) void {
        this.valid +%= 1;
      }

      // so we don't have this quite right. we 
      pub fn get(this: *This, from: From): Iterator {
        const value = this.backing.getPtr(this) orelse return switch (sort) {
          .append_only => .{ .valid = this.valid, .backing = .{ .slice = .empty, .index = 0 } },
          else => @compileError("TODO: Map.Get: ." ++ @tagName(sort)),
        };
        switch (sort) {
          .append_only => return .{ .valid = this.valid, .backing = .{ .slice = value.slice(), .index = 0 } },
          else => @compileError("TODO: Map.Get: ." ++ @tagName(sort)),
        }
      }

      fn getOrCreate(this: *This, gpa: std.mem.Allocator, from: From) *SortBacking {
        this.markInvalid();
        const gpres = this.backing.getOrPut(this);
        if (!gpres.found_existing) gpres.value_ptr.* = .empty;
        return gpres.value_ptr;
      }

      pub fn insertLast(this: *This, gpa: std.mem.Allocator, from: From, to: To) std.mem.Allocator.Error!void {
        const list = try this.getOrCreate(gpa, from);
        switch (sort) {
          .append_only => try list.append(to),
          else => @compileError("TODO: Map.insertLast: ." ++ @tagName(sort)),
        }
      }
    };
  }
  `;

  // TODO: generate the insert & get functions
  console.log(crender(cjoin(lines, cnl, undefined, cnl)));
}

initDb({
  classes: {
    "Text": {},
    "Text.Character": {
      owner: "Text",
      char: "u8",
      order: "Order",
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