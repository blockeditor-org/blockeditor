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
type UserQueryProvider = {arg: string} | "first" | "last" | {after: UserQueryProvider} | {before: UserQueryProvider} | {unique: string};
type UserQuerySortProvider = "asc" | "dsc";
type UserBaseQuery = {
    class: string,
    get: string[],
  };
type UserGetQuery = UserBaseQuery & {
  filter: {[key: string]: UserQueryProvider},
  sort: [string, UserQuerySortProvider][],
  limit?: number,
};
type UserDeleteQuery = UserBaseQuery & {
  filter: {[key: string]: UserQueryProvider},
  sort: [string, UserQuerySortProvider][],
  limit?: number,
  // arguably this should be the same as a get query: it should have get,sort,limit,...
};
type UserInsertQuery = UserBaseQuery & {
  insert: {[key: string]: UserQueryProvider},
};
type User = {
  classes: UserData,
  get: Record<string, UserGetQuery>,
  delete: Record<string, UserDeleteQuery>,
  insert: Record<string, UserInsertQuery>,
};
type ResolveDataFields = {

};
type ResolveType = {kind: "handle", class: string} | {kind: "u8"} | {kind: "Order"};
type ResolveQueryProvider = (
  | {kind: "arg", arg: string}
  | {kind: "Order.first"}
  | {kind: "Order.last"}
  | {kind: "Order.after", value: ResolveQueryProvider}
  | {kind: "Order.before", value: ResolveQueryProvider}
);
type ResolveClass = {
  fields: Map<string, ResolveType>,
};
type ResolveMapping = {
  name: string,
  class: string,
  fromFields: Set<string>,
  toFields: Set<string>,
  sortField: string,
  sortMode: ResolveSortMode,
  limit: number | undefined,
};
type ResolveSortMode = "none" | "appendOnly" | "appendPrepend" | "tree";
type Resolve = {
  mappings: ResolveMapping[],
  classes: Map<string, ResolveClass>,
  queries: {
    get: ResolveGetQuery[],
  },
};
type ResolveArg = {name: string, type: ResolveType};
type ResolveMappingKey = {name: string, value: ResolveQueryProvider};
type ResolveGetQuery = {
  name: string,
  args: ResolveArg[],
  mappingKeys: ResolveMappingKey[],
  mapping: ResolveMapping,
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
function amKey(am: Omit<ResolveMapping, "name">): string {
  return JSON.stringify({
    class: am.class,
    fromFields: [...am.fromFields].toSorted(),
    sortField: am.sortField,
    limit: am.limit,
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
function resolveType(rx: ResolveContext, userType: UserType): ResolveType {
  if (Object.hasOwn(rx.user.classes, userType)) {
    return {kind: "handle", class: userType};
  } else if (userType === "u8") {
    return {kind: "u8"};
  } else if (userType === "Order") {
    return {kind: "Order"};
  } else throw new Error("unsupported user type? " + userType);
}
type InferredArgsHelper = {
  clss: string,
  args: ResolveArg[],
};
function resolveQueryProvider(rx: ResolveContext, infer: InferredArgsHelper, slot: ResolveType, userQuery: UserQueryProvider): ResolveQueryProvider {
  if (userQuery === "first") return {kind: "Order.first"};
  if (userQuery === "last") return {kind: "Order.last"};
  if ('arg' in userQuery) {
    infer.args.push({name: userQuery.arg, type: slot});
    return {kind: "arg", arg: userQuery.arg};
  }
  if ('before' in userQuery) return {kind: "Order.before", value: resolveQueryProvider(rx, infer, {kind: "handle", class: infer.clss}, userQuery.before)};
  if ('after' in userQuery) return {kind: "Order.after", value: resolveQueryProvider(rx, infer, {kind: "handle", class: infer.clss}, userQuery.after)};
  throw new Error("unsupported user query? " + userQuery);
}
type ResolveContext = {
  user: User,
  amToMapping: Map<string, ResolveMapping>,
  csToMapping: Map<string, ResolveMapping[]>,
  allMappings: ResolveMapping[],
};
function getCS(rx: ResolveContext, cs: ResolveMappingCS): ResolveMapping[] {
  const key = csKey(cs);
  const list = rx.csToMapping.get(key) ?? [];
  rx.csToMapping.set(key, list);
  return list;
}
function addMapping(rx: ResolveContext, m: Omit<ResolveMapping, "name">): ResolveMapping {
  const am = amKey(m);
  const pm = rx.amToMapping.get(am)!;
  if (pm) {
    // extend the mapping rather than adding a new one
    pm.sortMode = unionSortMode(pm.sortMode, m.sortMode);
    for (const toField of m.toFields) {
      pm.toFields.add(toField);
    }
    return pm;
  }
  assert(completeMapping(m, am));
  rx.amToMapping.set(am, m);
  rx.allMappings.push(m);
  getCS(rx, {class: m.class, sortField: m.sortField}).push(m);
  return m;
}
function completeMapping(m: Omit<ResolveMapping, "name">, name: string): m is ResolveMapping {
  (m as ResolveMapping).name = name;
  return true;
}
function assert(b: boolean): asserts b { if (!b) throw new Error("not b") }
function initDb(user: User) {
  const allGetQueries: ResolveGetQuery[] = [];
  const rx: ResolveContext = {
    user,
    amToMapping: new Map(),
    csToMapping: new Map(),
    allMappings: [],
  };

  const allClasses: Map<string, ResolveClass> = new Map();
  for (const [name, desc] of Object.entries(user.classes)) {
    const resolveClass: ResolveClass = {fields: new Map()};
    for (const [fieldName, userType] of Object.entries(desc)) {
      resolveClass.fields.set(fieldName, resolveType(rx, userType));
    }
    allClasses.set(name, resolveClass);
  }

  for (const [name, value] of Object.entries(user.get)) {
    if (value.sort.length > 1) throw new Error("todo multi sort");
    if (value.sort.length === 0 && value.limit !== 1) throw new Error("todo no sort without limit set");
    const m = addMapping(rx, {
      class: value.class,
      fromFields: new Set(Object.entries(value.filter).map(([k]) => k)),
      toFields: new Set(value.get),
      sortField: value.sort[0]?.[0] ?? "",
      sortMode: "none",
      limit: value.limit,
    });
    const infer: InferredArgsHelper = {clss: value.class, args: []};
    const mappingKeys: ResolveMappingKey[] = Object.entries(value.filter).map(([k, v]): ResolveMappingKey => {
      const fieldType = allClasses.get(value.class)?.fields.get(k);
      if (!fieldType) throw new Error(`missing fieldType for ${value.class}/${k}`);
      return {name: k, value: resolveQueryProvider(rx, infer, fieldType, v)};
    });
    allGetQueries.push({
      name,
      args: infer.args,
      mappingKeys,
      mapping: m,
    });
  }
  for (const [name, value] of Object.entries(user.insert)) {
    for (const [insk, insv] of Object.entries(value.insert)) {
      const cs = getCS(rx, {class: value.class, sortField: insk});
      const intrinsicSortMode: ResolveSortMode = insv === "last" ? "appendOnly" : insv === "first" ? "appendPrepend" : "tree";
      for (const mapping of cs) {
        mapping.sortMode = unionSortMode(mapping.sortMode, intrinsicSortMode);
      }
    }
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
    mappings: rx.allMappings,
    classes: allClasses,
    queries: {
      get: allGetQueries,
    },
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

type CodegenCtx = {resolve: Resolve, handles: Set<string>};
function codegenType(ctx: CodegenCtx, type: ResolveType): Code {
  if (type.kind === "Order") {
    throw new Error("order should never be realized");
  } else if (type.kind === "handle") {
    ctx.handles.add(type.class);
    return c`${zigIdent(type.class)}`;
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
function codegenQueryProvider(ctx: CodegenCtx, queryProvider: ResolveQueryProvider): Code {
  if (queryProvider.kind === "arg") return zigIdent(queryProvider.arg);
  throw new Error("TODO codegenQueryProvider: "+queryProvider.kind);
}
const sortModeMap: {[key in ResolveSortMode]: Code} = {
  none: c`.none`,
  appendOnly: c`.append_only`,
  appendPrepend: c`.append_prepend`,
  tree: c`.tree`,
};

function codegen(resolve: Resolve) {
  const ctx: CodegenCtx = {resolve, handles: new Set()};
  const lines: Code[] = [];
  const mappingToNameMap = new Map<ResolveMapping, {type: string, value: string}>();

  lines.push(c`const lib = @import("lib.zig");`);

  const dbLines: Code[] = [];

  dbLines.push(c``, c`// Mappings`);
  lines.push(c``, c`// Mapping Types`);
  const mappingLines: Code[] = [];
  for (let i = 0; i < resolve.mappings.length; i++) {
    const mapping = resolve.mappings[i]!;
    // - give the mapping a name
    const typeName = `${mapping.class}.Mapping${i}`;
    const valueName = `${mapping.class}.mapping${i}`;
    mappingToNameMap.set(mapping, {type: typeName, value: valueName});
    // - generate the type, ie Map(Text.Handle, Sorted(struct {char: u8}))
    const from = codegenFieldsType(ctx, mapping.class, mapping.fromFields);
    const to = codegenFieldsType(ctx, mapping.class, mapping.toFields);
    const sort = sortModeMap[mapping.sortMode];
    const limit = mapping.limit != null ? c`.max(${craw(""+mapping.limit)})` : c`.unlimited`;
    const type = c`lib.Mapping(${sort}, ${limit}, ${from}, ${to})`;

    dbLines.push(c`${zigIdent(valueName)}: ${zigIdent(typeName)},`);
    lines.push(c`pub const ${zigIdent(typeName)} = ${type};`);

    // fn Map(K, V) return AutoArrayHashMap(K, V)
    // fn Sorted(T) switch(order) { .append_only => MultiArrayList(T), .rb_tree => RbTree(T) }
  }

  /*
  insert and get functions
  fn @"Text.new"(db: *Db, args: struct {}) std.mem.Allocator.Error!struct { @"$handle": Text.Handle } {
    const @"$handle" = try db.incrementer_Text.add();
    return .{ .@"$handle" = @"$handle" };
  }
  fn @"Text.push"(db: *Db, args: struct { owner: Text.Handle, char: u8 }) std.mem.Allocator.Error)@"Text.Character".Handle {
    try db.text_to_chars_map.insertLast(db.gpa, .{.owner = owner}, .{ .char = args.char });
  }
  */

  // TODO: generate the insert functions
  // for an insert function:
  // - find all mappings for the destination class
  // - duplicate the inserted data into all mappings

  lines.push(c``, c`// Get Functions`);
  for (const getFn of resolve.queries.get) {
    const mapping = mappingToNameMap.get(getFn.mapping)!;
    const args: Code[] = [];
    for (const arg of getFn.args) {
      args.push(c`${zigIdent(arg.name)}: ${codegenType(ctx, arg.type)},`);
    }
    const returnType: Code = c`${zigIdent(mapping.type)}.Iterator`;
    const bodyLines: Code[] = [];
    const mapKeys: Code[] = [];
    for (const key of getFn.mappingKeys) {
      mapKeys.push(c`.${zigIdent(key.name)} = ${codegenQueryProvider(ctx, key.value)},`);
    }
    bodyLines.push(c`return db.${zigIdent(mapping.value)}.get(.{${cnljoin(mapKeys)}});`);
    lines.push(c`pub fn ${zigIdent(getFn.name)}(db: *Db, args: struct {${cnljoin(args)}}) ${returnType} {${cnljoin(bodyLines)}}`); 
  }

  dbLines.push(c``, c`// Handle Incrementers`);
  lines.push(c``, c`// Handle Types`);
  for (const handle of [...ctx.handles].toSorted()) {
    dbLines.push(c`${zigIdent("incrementer_" + handle)}: lib.Incrementer(${zigIdent(handle)}),`);
    lines.push(c`pub const ${zigIdent(handle)} = enum(usize) { _ };`);
  }

  lines.push(c``, c`pub const Db = struct {${cnljoin(dbLines)}};`);

  // serialization:
  // - we only need to serialize enough data to be able to reconstruct the mappings
  // - then when we deserialize, we reconstruct the mappings

  const lib = `
  const std = @import("std");

  pub fn Incrementer(comptime Handle: type) type {
    return struct {
      last: Handle,
      pub const empty: Holder = .{ .last = @enumFromInt(0) };
      pub fn add(self: *Holder) !This {
        return @enumFromInt(0); // TODO
      }
      pub fn remove(self: *Holder, item: This) void {
        _ = self;
        _ = item;
        // TODO
      }
    };
  }

  pub const SortMode = enum { none, append_only, append_prepend, tree };
  pub const MappingLimit = enum(usize) {
    unlimited = std.math.maxInt(usize),
    _
    pub fn from(value: ?usize) MappingLimit {
      if (value) |v| return @enumFromInt(v);
      return .unlimited;
    }
  };
  pub fn Mapping(comptime sort: SortMode, comptime limit: MappingLimit, comptime From: type, comptime To: type) type {
    _ = limit;
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

  console.log(crender(cjoin(lines, cnl, undefined, cnl)));
}

initDb({
  classes: {
    "Text": {
      handle: "Text",
    },
    "Text.Character": {
      owner: "Text", // a handle type is really just as if an extra field was added onto 'text' called 'unique autoincrementing id: usize'
      char: "u8",
      order: "Order",
    },
    "Grid": {
      handle: "Grid",
    },
    "Grid.Pixel": {
      owner: "Text",
      x: "u8",
      y: "u8",
      value: "u8",
    },
  },
  // we could define mappings manually instead of inferring them from queries
  // a mapping would be eg: {class: "Text.Character", filter: ["owner"], sort: [["order", "asc"]], get: ["char"], limit: 1}
  // and then the queries would reference mappings
  get: {
    "Text.body": {class: "Text.Character", filter: {owner: {arg: "text"}}, sort: [["order", "asc"]], get: ["char"]},
    "Grid.at": {class: "Grid.Pixel", filter: {owner: {arg: "grid"}, x: {arg: "x"}, y: {arg: "y"}}, sort: [], limit: 1, get: ["value"]},
  },
  delete: {
    "Text.clear": {class: "Text.Character", filter: {owner: {arg: "text"}}, sort: [], get: []},
    "Text.delete": {class: "Text", filter: {handle: {arg: "text"}}, sort: [], get: []},
  },
  insert: {
    "Text.new": {class: "Text", insert: {handle: {unique: "Text"}}, get: ["handle"]},
    "Text.push": {class: "Text.Character", insert: {owner: {arg: "owner"}, char: {arg: "char"}, order: "last"}, get: []},
    "Grid.new": {class: "Text", insert: {handle: {unique: "Grid"}}, get: ["handle"]},
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