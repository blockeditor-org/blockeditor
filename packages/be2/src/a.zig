fn ListComponent(comptime T: type) void {
    return struct {
        generation: u64, // increments after every operation

        const Operation = struct {
            generation: u64, // this operation is intended to be applied to the document with this generation
            items: []union(enum) {
                splice: struct {
                    offset: u64,
                    delete: u64,
                    insert: []const T,
                },
                move: struct {
                    from: u64,
                    len: u64,
                    to: u64,
                },
            },
        };

        // basics:
        //   serialize() -> struct { data: []const u8, references: []const sorted u128 }
        //   deserialize(data: []const u8) -> @This()
        //   upgrade(old_data: []const u8, old_version: u128) -> @This()
        //
        // for collaboration:
        //   transform(op_a, op_b) -> op_b_t
        //       takes op_b and modifies it to be able to apply after op_a
        //   diff(state_a, state_b) -> ???
        //       for offline edits when OT is more likely to make bad decisions
    };
}
