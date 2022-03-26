const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const bog = @import("bog.zig");
const Node = bog.Node;
const Type = bog.Type;

const Bytecode = @This();

code: Inst.List.Slice,
extra: []const Ref,

main: []const u32,

strings: []const u8,
debug_info: DebugInfo,

pub fn deinit(b: *Bytecode, gpa: Allocator) void {
    gpa.free(b.extra);
    gpa.free(b.main);
    gpa.free(b.strings);
    b.debug_info.lines.deinit(gpa);
    gpa.free(b.debug_info.path);
    gpa.free(b.debug_info.source);
    b.code.deinit(gpa);
    b.* = undefined;
}

pub const Ref = enum(u32) {
    _,
    pub fn format(ref: Ref, _: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        var buf: [8]u8 = undefined;
        buf[0] = '%';
        const end = std.fmt.formatIntBuf(buf[1..], @enumToInt(ref), 10, .lower, .{});
        try std.fmt.formatBuf(buf[0 .. end + 1], options, writer);
    }
};

pub inline fn indexToRef(i: u64, params: u32) Ref {
    return @intToEnum(Ref, i + params);
}
pub inline fn refToIndex(r: Ref, params: u32) u32 {
    return @enumToInt(r) - params;
}

/// All integers are little endian
pub const Inst = struct {
    op: Op,
    data: Data,

    pub const List = std.MultiArrayList(Inst);

    pub const Op = enum(u8) {
        /// No operation.
        nop,

        // literal construction

        /// null, true, false
        primitive,
        /// integer literal
        int,
        /// number literal
        num,
        // string literal
        str,

        // aggregate construction

        // use Data.extra
        build_tuple,
        build_list,
        build_map,
        // use Data.un
        build_error,
        build_error_null,
        /// uses Data.extra with
        /// extra[0] == operand
        /// extra[1] == str.offset
        build_tagged,
        /// uses Data.str
        build_tagged_null,
        /// uses Data.extra with
        /// extra[0] == args_len
        /// extra[1..] == body
        build_func,
        /// uses Data.extra with
        /// extra[0] == args_len
        /// extra[1] == captures_len
        /// extra[2..][0..captures_len] == captures
        /// extra[2 + captures_len..] == body
        build_func_capture,
        /// uses Data.bin
        build_range,
        /// uses Data.range
        build_range_step,

        // import, uses Data.str
        import,

        // discards Data.un, complains if it's an error
        discard,

        // res = copy(operand)
        copy_un,
        // lhs = copy(rhs)
        copy,
        // lhs = rhs
        move,
        // res = GLOBAL(operand)
        load_global,
        // res = CAPTURE(operand)
        load_capture,
        // res = THIS
        load_this,

        // binary operators

        // numeric
        div_floor,
        div,
        mul,
        pow,
        rem,
        add,
        sub,

        // bitwise
        l_shift,
        r_shift,
        bit_and,
        bit_or,
        bit_xor,

        // comparisons
        equal,
        not_equal,
        less_than,
        less_than_equal,
        greater_than,
        greater_than_equal,

        /// lhs in rhs
        in,

        /// container(lhs).append(rhs)
        append,

        // simple cast
        as,
        // simple type check
        is,

        // unary operations
        negate,
        bool_not,
        bit_not,

        // uses Data.un, error(A) => A
        unwrap_error,
        // uses Data.str, @tag(A) => A
        unwrap_tagged,
        unwrap_tagged_or_null,

        // uses Data.bin
        // returns null if lhs is not tuple/list or if its len is not equal to @enumToInt(rhs)
        check_len,
        // same as above but return error on false
        assert_len,

        // use Data.bin
        get,
        // returns null if no
        get_or_null,
        // uses Data.range with
        // start == container
        // extra[0] == index
        // extra[1] == value
        set,

        /// uses Data.jump_condition
        /// Operand is where the error value should be stored
        /// and offset is where the VM should jump to handle the error.
        push_err_handler,
        pop_err_handler,

        // uses Data.jump
        jump,
        // use Data.jump_condition
        jump_if_true,
        jump_if_false,
        jump_if_null,
        /// if operand is not an error jumps,
        /// otherwise unwraps the error
        unwrap_error_or_jump,

        // use Data.un
        iter_init,
        // use Data.jump_condition
        iter_next,

        /// uses Data.extra with 
        /// extra[0] == callee
        call,
        /// uses Data.bin, lhs(rhs)
        call_one,
        /// uses Data.un, operand()
        call_zero,
        /// Same as `call` but this is passed as the first argument.
        this_call,
        /// uses Data.bin, lhs(this)
        this_call_zero,

        // use Data.un
        ret,
        ret_null,
        throw,

        pub fn needsDebugInfo(op: Op) bool {
            return switch (op) {
                // zig fmt: off
                .call, .call_one, .call_zero, .this_call, .this_call_zero, .set,
                .get, .assert_len, .unwrap_tagged, .unwrap_error, .bit_not,
                .bool_not, .negate, .as, .in, .less_than, .less_than_equal,
                .greater_than, .greater_than_equal, .mul, .pow, .add, .sub,
                .l_shift, .r_shift, .bit_and, .bit_or, .bit_xor, .rem, .div,
                .div_floor, .import, .build_range_step, .build_range,
                .iter_init, .iter_next => true,
                // zig fmt: on
                else => false,
            };
        }

        pub fn hasResult(op: Op) bool {
            return switch (op) {
                // zig fmt: off
                .discard, .copy, .move, .append, .check_len,
                .assert_len, .set, .push_err_handler, .pop_err_handler,
                .jump, .jump_if_true, .jump_if_false, .jump_if_null, .ret,
                .ret_null, .throw => false,
                // zig fmt: on
                else => true,
            };
        }
    };

    pub const Data = union {
        none: void,
        primitive: enum {
            @"null",
            @"true",
            @"false",
        },
        int: i64,
        num: f64,
        str: struct {
            offset: u32,
            len: u32,
        },
        extra: struct {
            extra: u32,
            len: u32,
        },
        range: struct {
            start: Ref,
            /// end = extra[extra]
            /// step = extra[extra + 1]
            extra: u32,
        },
        bin: struct {
            lhs: Ref,
            rhs: Ref,
        },
        bin_ty: struct {
            operand: Ref,
            ty: Type,
        },
        un: Ref,
        jump: u32,
        jump_condition: struct {
            operand: Ref,
            offset: u32,
        },
    };

    comptime {
        if (!std.debug.runtime_safety) std.debug.assert(@sizeOf(Data) == @sizeOf(u64));
    }
};

pub const DebugInfo = struct {
    path: []const u8 = "",
    source: []const u8 = "",
    lines: Lines,

    pub const Lines = std.AutoHashMapUnmanaged(u32, u32);
};

fn dumpLineCol(b: *Bytecode, byte_offset: u32) void {
    var start: u32 = 0;
    // find the start of the line which is either a newline or a splice
    var line_num: u32 = 1;
    var i: u32 = 0;
    while (i < byte_offset) : (i += 1) {
        if (b.debug_info.source[i] == '\n') {
            start = i + 1;
            line_num += 1;
        }
    }
    const col_num = byte_offset - start + 1;
    std.debug.print("{s}:{d}:{d}\n", .{ b.debug_info.path, line_num, col_num });
}

pub fn dump(b: *Bytecode, body: []const u32, params: u32) void {
    const ops = b.code.items(.op);
    const data = b.code.items(.data);
    for (body) |i, inst| {
        if (ops[i] == .nop) continue;
        const ref = indexToRef(inst, params);
        if (ops[i].needsDebugInfo()) {
            dumpLineCol(b, b.debug_info.lines.get(@intCast(u32, i)).?);
        }
        std.debug.print("{d:4} ", .{inst});
        if (ops[i].hasResult()) {
            std.debug.print("{:4} = ", .{ref});
        } else {
            std.debug.print("       ", .{});
        }
        std.debug.print("{s} ", .{@tagName(ops[i])});
        switch (ops[i]) {
            .nop => unreachable,
            .primitive => std.debug.print("{s}\n", .{@tagName(data[i].primitive)}),
            .int => std.debug.print("{d}\n", .{data[i].int}),
            .num => std.debug.print("{d}\n", .{data[i].num}),
            .import, .str, .unwrap_tagged, .unwrap_tagged_or_null => {
                const str = b.strings[data[i].str.offset..][0..data[i].str.len];
                std.debug.print("{s}\n", .{str});
            },
            .build_tuple => {
                const extra = b.extra[data[i].extra.extra..][0..data[i].extra.len];
                std.debug.print("(", .{});
                dumpList(extra);
                std.debug.print(")\n", .{});
            },
            .build_list => {
                const extra = b.extra[data[i].extra.extra..][0..data[i].extra.len];
                std.debug.print("[", .{});
                dumpList(extra);
                std.debug.print("]\n", .{});
            },
            .build_map => {
                const extra = b.extra[data[i].extra.extra..][0..data[i].extra.len];
                std.debug.print("{{", .{});
                var extra_i: u32 = 0;
                while (extra_i < extra.len) : (extra_i += 2) {
                    if (extra_i != 0) std.debug.print(", ", .{});
                    std.debug.print("{} = {}", .{ extra[extra_i], extra[extra_i + 1] });
                }
                std.debug.print("}}\n", .{});
            },
            .build_func => {
                const extra = b.extra[data[i].extra.extra..][0..data[i].extra.len];
                const args = @enumToInt(extra[0]);
                const fn_body = @bitCast([]const u32, extra[1..]);
                std.debug.print("\n\nfn(args: {d}) {{\n", .{args});
                b.dump(fn_body, args);
                std.debug.print("}}\n\n", .{});
            },
            .build_func_capture => {
                const extra = b.extra[data[i].extra.extra..][0..data[i].extra.len];
                const args = @enumToInt(extra[0]);
                const captures_len = @enumToInt(extra[1]);
                const fn_captures = extra[2..][0..captures_len];
                const fn_body = @bitCast([]const u32, extra[2 + captures_len ..]);
                std.debug.print("\n\nfn(args: {d}, captures: [", .{args});
                dumpList(fn_captures);
                std.debug.print("]) {{\n", .{});
                b.dump(fn_body, args);
                std.debug.print("}}\n\n", .{});
            },
            .build_tagged_null => {
                const str = b.strings[data[i].str.offset..][0..data[i].str.len];
                std.debug.print("@{s} = null\n", .{str});
            },
            .build_tagged => {
                const operand = b.extra[data[i].extra.extra];
                const str_offset = @enumToInt(b.extra[data[i].extra.extra + 1]);
                const str = b.strings[str_offset..][0..data[i].extra.len];
                std.debug.print("@{s} = {}\n", .{ str, operand });
            },
            .build_range => std.debug.print("{}:{}\n", .{ data[i].bin.lhs, data[i].bin.rhs }),
            .build_range_step => {
                const start = data[i].range.start;
                const end = b.extra[data[i].range.extra];
                const step = b.extra[data[i].range.extra + 1];
                std.debug.print("{}:{}:{}\n", .{ start, end, step });
            },
            .set => {
                const container = data[i].range.start;
                const index = b.extra[data[i].range.extra];
                const val = b.extra[data[i].range.extra + 1];
                std.debug.print("{}[{}] = {}\n", .{ container, index, val });
            },
            .check_len,
            .assert_len,
            => {
                const operand = data[i].bin.lhs;
                const len = @enumToInt(data[i].bin.rhs);
                std.debug.print("{} {d}\n", .{ operand, len });
            },
            .load_global => std.debug.print("GLOBAL({})\n", .{data[i].un}),
            .load_capture => std.debug.print("CAPTURE({d})\n", .{@enumToInt(data[i].un)}),
            .copy,
            .move,
            .get,
            .get_or_null,
            .div_floor,
            .div,
            .mul,
            .pow,
            .rem,
            .add,
            .sub,
            .l_shift,
            .r_shift,
            .bit_and,
            .bit_or,
            .bit_xor,
            .equal,
            .not_equal,
            .less_than,
            .less_than_equal,
            .greater_than,
            .greater_than_equal,
            .in,
            => std.debug.print("{} {}\n", .{ data[i].bin.lhs, data[i].bin.rhs }),
            .append => std.debug.print("{}.append({})\n", .{ data[i].bin.lhs, data[i].bin.rhs }),
            .as, .is => std.debug.print("{} {s}\n", .{ data[i].bin_ty.operand, @tagName(data[i].bin_ty.ty) }),
            .ret,
            .throw,
            .negate,
            .bool_not,
            .bit_not,
            .unwrap_error,
            .iter_init,
            .discard,
            .build_error,
            .copy_un,
            => std.debug.print("{}\n", .{data[i].un}),
            .pop_err_handler,
            .jump,
            => std.debug.print("{d}\n", .{data[i].jump}),
            .jump_if_true,
            .jump_if_false,
            .unwrap_error_or_jump,
            .jump_if_null,
            .iter_next,
            .push_err_handler,
            => std.debug.print(
                "{d} cond {}\n",
                .{ data[i].jump_condition.offset, data[i].jump_condition.operand },
            ),
            .call => {
                const extra = b.extra[data[i].extra.extra..][0..data[i].extra.len];
                std.debug.print("{}(", .{extra[0]});
                dumpList(extra[1..]);
                std.debug.print(")\n", .{});
            },
            .this_call => {
                const extra = b.extra[data[i].extra.extra..][0..data[i].extra.len];
                std.debug.print("{}.{}(", .{ extra[1], extra[0] });
                dumpList(extra[2..]);
                std.debug.print(")\n", .{});
            },
            .call_one => std.debug.print("{}({})\n", .{ data[i].bin.lhs, data[i].bin.rhs }),
            .this_call_zero => std.debug.print("{}.{}()\n", .{ data[i].bin.rhs, data[i].bin.lhs }),
            .call_zero => std.debug.print("{}()\n", .{data[i].un}),
            .ret_null,
            .build_error_null,
            .load_this,
            => std.debug.print("\n", .{}),
        }
    }
}

fn dumpList(list: []const Ref) void {
    for (list) |item, i| {
        if (i != 0) std.debug.print(", ", .{});
        std.debug.print("{}", .{item});
    }
}