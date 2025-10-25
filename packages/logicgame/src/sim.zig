const std = @import("std");

const Simulator = struct {};

const Wire = usize;

pub fn main() !u8 {
    var arena_alloc = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena_alloc.deinit();
    const arena = arena_alloc.allocator();

    const fcontents = try std.fs.cwd().readFileAlloc(arena, "src/example.lg", std.math.maxInt(usize));
    const component = Component.parse(arena, fcontents) catch |e| switch (e) {
        error.OutOfMemory => return e,
        error.ParseError => return 1,
    };
    _ = component;
    return 0;
}

const Parser = struct {
    const Srcloc = usize;
    components: std.StringArrayHashMapUnmanaged(*ParserCompleteComponent) = .empty,
    active_component: ?ParserComponent = null,
    arena: std.mem.Allocator,
    has_errors: bool = false,
    tests: std.ArrayList(ParserTest) = .empty,

    const ParserCompleteComponent = struct {
        written: bool,
        loc: Srcloc,
        value: Component,

        expected_inputs: usize,
        expected_outputs: usize,
    };
    const ParserTest = struct {
        loc: usize,
        component: *ParserCompleteComponent,
        inputs: []u64,
        expected_masks: []u64,
        expected_outputs: []u64,
    };

    const ParserComponent = struct {
        loc: Srcloc,
        name: []const u8,
        wire_states: std.StringArrayHashMapUnmanaged(Srcloc) = .empty,
        instructions: std.ArrayList(SimulationInstruction) = .empty,
        inputs: std.ArrayList(Wire) = .empty,
        arena: std.mem.Allocator,

        fn getWireState(component: *ParserComponent, parser: *Parser, loc: Srcloc, label: []const u8, mode: enum { any, get, add }) !Wire {
            const gpres = try component.wire_states.getOrPut(component.arena, label);
            if (gpres.found_existing) {
                if (mode == .add) return parser.err(loc, "wire state `{s}` already defined\nnote: src/example.lg:{d}: previous definition here", .{ label, gpres.value_ptr.* });
                return gpres.index;
            }
            if (mode == .get) return parser.err(loc, "wire state `{s}` not defined", .{label});
            gpres.value_ptr.* = loc;
            return gpres.index;
        }
    };

    fn getComponent(parser: *Parser, loc: Srcloc, label: []const u8, expected_inputs: usize, expected_outputs: usize) !*ParserCompleteComponent {
        const gpres = try parser.components.getOrPut(parser.arena, label);
        if (gpres.found_existing) {
            if (gpres.value_ptr.*.*.expected_inputs != expected_inputs or gpres.value_ptr.*.*.expected_outputs != expected_outputs) {
                return parser.err(loc, "mismatched args counts\nnote: src/example.lg:{d}: previous here", .{gpres.value_ptr.*.*.loc});
            }
            return gpres.value_ptr.*;
        }
        gpres.value_ptr.* = try parser.arena.create(ParserCompleteComponent);
        gpres.value_ptr.*.* = .{
            .written = false,
            .loc = loc,
            .value = undefined,
            .expected_inputs = expected_inputs,
            .expected_outputs = expected_outputs,
        };
        return gpres.value_ptr.*;
    }

    fn err(parser: *Parser, loc: Srcloc, comptime fmt: []const u8, arg: anytype) error{ParseError} {
        std.log.err("src/example.lg:{d}: " ++ fmt, .{loc} ++ arg);
        parser.has_errors = true;
        return error.ParseError;
    }

    fn parseInt(parser: *Parser, loc: Srcloc, num: []const u8) !u64 {
        const result = std.fmt.parseInt(i128, num, 0) catch return parser.err(loc, "bad number", .{});
        if (result < std.math.minInt(i64)) return parser.err(loc, "number out of range: {d} < {d}", .{ result, std.math.minInt(i64) });
        if (result > std.math.maxInt(u64)) return parser.err(loc, "number out of range: {d} > {d}", .{ result, std.math.maxInt(u64) });
        const u: u128 = @bitCast(result);
        return @truncate(u);
    }
    const SizedInt = struct { mask: u64, int: u64 };
    fn parseSizedInt(parser: *Parser, loc: Srcloc, num: []const u8) !SizedInt {
        var split = std.mem.splitScalar(u8, num, '/');
        const size = try parser.parseInt(loc, split.next() orelse return parser.err(loc, "missing split lhs", .{}));
        const value = try parser.parseInt(loc, split.next() orelse return parser.err(loc, "missing split rhs", .{}));
        if (split.next() != null) return parser.err(loc, "extra slash", .{});
        if (size > 64) return parser.err(loc, "size out of range", .{});
        const mask: u64 = (@as(u64, 1) << @as(u6, @intCast(size))) - 1;
        return .{ .mask = mask, .int = value & mask };
    }

    fn parseLine(parser: *Parser, loc: Srcloc, line: []const u8) !void {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) return;
        if (std.mem.startsWith(u8, trimmed, "#")) return;

        var space_iter = std.mem.tokenizeScalar(u8, trimmed, ' ');
        const instruction = space_iter.next() orelse return parser.err(loc, "empty line", .{});
        if (std.mem.eql(u8, instruction, "DEFINE")) {
            if (parser.active_component != null) {
                return parser.err(loc, "DEFINE while active component extant\nnote: src/example.lg:{d}: current definition here", .{parser.active_component.?.loc});
            }
            const name = space_iter.next() orelse return parser.err(loc, "missing DEFINE name", .{});
            const arrow = space_iter.next() orelse return parser.err(loc, "missing DEFINE arrow", .{});
            if (!std.mem.eql(u8, arrow, "->")) return parser.err(loc, "bad arrow", .{});

            parser.active_component = .{
                .loc = loc,
                .name = name,
                .arena = parser.arena,
            };
            var component = &parser.active_component.?;

            while (space_iter.next()) |item| {
                try component.inputs.append(parser.arena, try component.getWireState(parser, loc, item, .add));
            }
            return;
        } else if (std.mem.eql(u8, instruction, "TEST")) {
            const name = space_iter.next() orelse return parser.err(loc, "missing test name", .{});
            if (parser.active_component != null and !std.mem.eql(u8, name, parser.active_component.?.name)) {
                return parser.err(loc, "TEST in component must have same name", .{});
            }
            var inputs = std.ArrayList(u64).empty;
            var masks = std.ArrayList(u64).empty;
            var outputs = std.ArrayList(u64).empty;
            while (space_iter.next()) |item| {
                if (std.mem.eql(u8, item, "->")) break;
                try inputs.append(parser.arena, try parser.parseInt(loc, item));
            } else return parser.err(loc, "missing `->`", .{});
            while (space_iter.next()) |item| {
                const so = try parser.parseSizedInt(loc, item);
                try masks.append(parser.arena, so.mask);
                try outputs.append(parser.arena, so.int);
            }

            const complete = try parser.getComponent(loc, name, inputs.items.len, outputs.items.len);
            try parser.tests.append(parser.arena, .{
                .loc = loc,
                .component = complete,
                .inputs = try inputs.toOwnedSlice(parser.arena),
                .expected_masks = try masks.toOwnedSlice(parser.arena),
                .expected_outputs = try outputs.toOwnedSlice(parser.arena),
            });
            return;
        }
        if (parser.active_component == null) return parser.err(loc, "missing active component", .{});
        var component = &parser.active_component.?;

        if (std.mem.eql(u8, instruction, "OUTPUT")) {
            defer parser.active_component = null; // end component regardless of if we succeeded or not
            var outputs = std.ArrayList(Wire).empty;
            while (space_iter.next()) |item| {
                try outputs.append(parser.arena, try component.getWireState(parser, loc, item, .get));
            }

            const wire_states = try parser.arena.alloc(u64, component.wire_states.count());
            @memset(wire_states, 0);
            const default_outputs = try parser.arena.alloc(u64, outputs.items.len);
            @memset(default_outputs, 0);

            const final = try parser.getComponent(loc, component.name, component.inputs.items.len, outputs.items.len);
            if (final.written) return parser.err(loc, "duplicate component definition `{s}`\nnote: src/example.lg:{d}: previous definition here", .{ component.name, component.loc });

            final.loc = loc;
            final.value = .{
                .wire_states = wire_states,
                .instructions = try component.instructions.toOwnedSlice(parser.arena),
                .inputs = try component.inputs.toOwnedSlice(parser.arena),
                .outputs = try outputs.toOwnedSlice(parser.arena),
                .default_outputs = default_outputs,
                .default_outputs_filled = false,
            };
            final.written = true;
            return;
        } else if (std.mem.eql(u8, instruction, "CALL")) {
            const name = space_iter.next() orelse return parser.err(loc, "missing call name", .{});

            var inputs = std.ArrayList(Wire).empty;
            var outputs = std.ArrayList(Wire).empty;
            while (space_iter.next()) |item| {
                if (std.mem.eql(u8, item, "->")) break;
                try inputs.append(parser.arena, try component.getWireState(parser, loc, item, .get));
            } else return parser.err(loc, "missing `->`", .{});
            while (space_iter.next()) |item| {
                try outputs.append(parser.arena, try component.getWireState(parser, loc, item, .any));
            }

            const target = try parser.getComponent(loc, name, inputs.items.len, outputs.items.len);
            try component.instructions.append(parser.arena, .{
                .call = .{
                    .component = &target.value,
                    .args = try inputs.toOwnedSlice(parser.arena),
                    .ret = try outputs.toOwnedSlice(parser.arena),
                },
            });
            return;
        }

        var inputs = std.ArrayList(Wire).empty;
        var outputs = std.ArrayList(Wire).empty;
        while (space_iter.next()) |item| {
            if (std.mem.eql(u8, item, "->")) break;
            try inputs.append(parser.arena, try component.getWireState(parser, loc, item, .get));
        } else return parser.err(loc, "missing `->`", .{});
        while (space_iter.next()) |item| {
            try outputs.append(parser.arena, try component.getWireState(parser, loc, item, .any));
        }

        const entry = name_to_instruction_map.get(instruction) orelse return parser.err(loc, "TODO instruction `{s}`\nnote: src/{s}:{d}: implement here", .{ instruction, @src().file, @src().line });

        std.debug.assert(entry.args + entry.rets <= 5);
        if (inputs.items.len != entry.args) return parser.err(loc, "expected {d} inputs, got {d}", .{ entry.args, inputs.items.len });
        if (outputs.items.len != entry.rets) return parser.err(loc, "expected {d} outputs, got {d}", .{ entry.rets, outputs.items.len });
        var result: [5]Wire = @splat(0);
        @memcpy(result[0..entry.args], inputs.items);
        @memcpy(result[entry.args..][0..entry.rets], outputs.items);
        try component.instructions.append(component.arena, .{ .basic = .{ .tag = entry.tag, .value = result } });
    }

    const InstrDesc = struct {
        tag: SimulationInstructionTag,
        args: usize,
        rets: usize,
    };
    const name_to_instruction_map = std.StaticStringMap(InstrDesc).initComptime(.{
        .{ "ZERO", InstrDesc{ .tag = .zero, .args = 0, .rets = 1 } },
        .{ "NOT", InstrDesc{ .tag = .not, .args = 1, .rets = 1 } },
        .{ "ADD-4", InstrDesc{ .tag = .add_4, .args = 2, .rets = 2 } },
        .{ "SPLIT-4-1", InstrDesc{ .tag = .split_4_1, .args = 1, .rets = 4 } },
        .{ "JOIN-1-4", InstrDesc{ .tag = .join_1_4, .args = 4, .rets = 1 } },
    });
};

const Component = struct {
    // TODO: we'll want to store input masks, otherwise we will improperly detect eg 0b1110 as non-zero when it is only used as 1 bit
    wire_states: []u64,
    instructions: []SimulationInstruction,
    inputs: []Wire,
    outputs: []Wire,
    default_outputs: []u64, // if we go the route of having 'transistor' be the only base component, this will always be @splat(0) so it's worthless
    default_outputs_filled: bool,
    active_instruction: usize = 0,
    simulating: bool = false,

    fn parse(arena: std.mem.Allocator, src: []const u8) !*Component {
        var parser = Parser{ .arena = arena };

        var lines_iter = std.mem.splitScalar(u8, src, '\n');
        var loc: Parser.Srcloc = 1;
        while (lines_iter.next()) |line| : (loc += 1) {
            parser.parseLine(loc, line) catch |err| switch (err) {
                error.OutOfMemory => return err,
                error.ParseError => continue,
            };
        }

        if (parser.active_component != null) parser.err(parser.active_component.?.loc, "unfinished component", .{}) catch {};
        for (parser.components.entries.items(.key), parser.components.entries.items(.value)) |name, component| {
            if (!component.written) {
                parser.err(component.loc, "component not defined: `{s}`", .{name}) catch {};
            }
        }

        if (parser.components.count() < 1) parser.err(loc, "Must define at least one component", .{}) catch {};
        if (parser.has_errors) return error.ParseError;

        // fill default_outputs for all components, only if there were no errors
        for (parser.components.entries.items(.value)) |component| {
            std.debug.assert(component.written);
            if (component.value.default_outputs_filled) continue;
            const owner_states = try arena.alloc(u64, @max(component.expected_inputs, component.expected_outputs));
            const owner_inputs = try arena.alloc(Wire, component.expected_inputs);
            const owner_outputs = try arena.alloc(Wire, component.expected_outputs);
            for (owner_states) |*a| a.* = 0;
            for (owner_inputs, 0..) |*a, i| a.* = i;
            for (owner_outputs, 0..) |*a, i| a.* = i;
            component.value.simulate(owner_states, owner_inputs, owner_outputs);
            std.debug.assert(component.value.default_outputs_filled);
        }

        // run tests, only if there were no errors
        for (parser.tests.items) |parser_test| {
            const component = parser_test.component;
            const owner_states = try arena.alloc(u64, @max(component.expected_inputs, component.expected_outputs));
            const owner_inputs = try arena.alloc(Wire, component.expected_inputs);
            const owner_outputs = try arena.alloc(Wire, component.expected_outputs);
            for (owner_states) |*a| a.* = 0;
            for (owner_inputs, 0..) |*a, i| a.* = i;
            for (owner_outputs, 0..) |*a, i| a.* = i;
            @memcpy(owner_states[0..component.expected_inputs], parser_test.inputs);
            component.value.simulate(owner_states, owner_inputs, owner_outputs);
            const outputs = owner_states[0..component.expected_outputs];
            for (parser_test.expected_outputs, outputs) |mask, *o| o.* &= mask;
            if (!std.mem.eql(u64, parser_test.expected_outputs, outputs)) {
                parser.err(parser_test.loc, "Test failure:\n  Expected: {any}\n  Received: {any}", .{ parser_test.expected_outputs, outputs }) catch {};
            }
        }
        if (parser.has_errors) return error.ParseError; // because multiple tests can fail seperately

        return &parser.components.entries.items(.value)[0].value;
    }

    fn simulate(this: *Component, owner_states: []u64, owner_inputs: []Wire, owner_outputs: []Wire) void {
        std.debug.assert(!this.simulating); // recursive call not allowed
        this.simulating = true;
        defer this.simulating = false;

        const inputs_all_zero = for (owner_inputs) |arg| {
            if (owner_states[arg] != 0) break false;
        } else true;
        if (inputs_all_zero and this.default_outputs_filled) {
            for (owner_outputs, this.default_outputs) |oo, do| owner_states[oo] = do;
            return;
        }

        this.active_instruction = 0;
        @memset(this.wire_states, 0); // unnecessary but why not
        for (owner_inputs, this.inputs) |oi, ti| this.wire_states[ti] = owner_states[oi];

        while (this.active_instruction < this.instructions.len) {
            switch (this.instructions[this.active_instruction]) {
                .call => |c| c.component.simulate(this.wire_states, c.args, c.ret),
                .basic => |basic| {
                    const a, const b, const c, const d, const e = basic.value;
                    switch (basic.tag) {
                        .transistor_64_1 => {
                            const t: u64 = if (this.wire_states[a] & 1 == 1) std.math.maxInt(u64) else 0;
                            this.wire_states[c] = t & ~this.wire_states[b];
                        },
                        .transistor_64_64 => this.wire_states[c] = this.wire_states[a] & ~this.wire_states[b],
                        .@"and" => this.wire_states[c] = this.wire_states[a] & this.wire_states[b],
                        .@"or" => this.wire_states[c] = this.wire_states[a] | this.wire_states[b],
                        .xor => this.wire_states[c] = this.wire_states[a] ^ this.wire_states[b],
                        .not => this.wire_states[b] = ~this.wire_states[a],
                        .zero => this.wire_states[a] = 0,
                        .add_4 => {
                            const lhs: u4 = @truncate(this.wire_states[a]);
                            const rhs: u4 = @truncate(this.wire_states[b]);
                            const ret, const overflow = @addWithOverflow(lhs, rhs);
                            this.wire_states[c] = ret;
                            this.wire_states[d] = overflow;
                        },
                        .join_1_4 => {
                            var res: u64 = 0;
                            res |= this.wire_states[a] & 0b1;
                            res <<= 1;
                            res |= this.wire_states[b] & 0b1;
                            res <<= 1;
                            res |= this.wire_states[c] & 0b1;
                            res <<= 1;
                            res |= this.wire_states[d] & 0b1;
                            this.wire_states[e] = res;
                        },
                        else => @panic(@tagName(basic.tag)),
                    }
                },
            }
            this.active_instruction += 1;
        }

        for (owner_outputs, this.outputs) |oi, ti| owner_states[oi] = this.wire_states[ti];
        if (inputs_all_zero and !this.default_outputs_filled) {
            for (this.default_outputs, this.outputs) |*oi, ti| {
                oi.* = this.wire_states[ti];
            }
            this.default_outputs_filled = true;
        }
    }
};

const SimulationInstructionTag = enum {
    transistor_64_1, // a1: pwr, b64: cond, c64: output
    transistor_64_64, // a64: pwr, b64: cond, c64: output
    zero, // => a64: out
    not, // a64: lhs => b64: out (unclear if we will include this or not)
    @"and", // a64: lhs, b64: rhs => c64: out
    @"or",
    xor,
    add_1,
    add_2,
    add_4,
    add_8,
    add_16,
    add_32,
    add_64,
    split_4_2, // 4a -> 2b 2c
    split_4_1, // 4a -> 1b 1c 1d 1e
    join_1_4, // 1a 1b 1c 1d -> 4e
    join_2_4, // 2a 2b -> 4c
};
const SimulationInstruction = union(enum) {
    call: CallArgs,
    basic: struct { tag: SimulationInstructionTag, value: [5]Wire },
};

const Basic = [5]Wire;

const CallArgs = struct {
    component: *Component,
    args: []Wire,
    ret: []Wire,
};
