const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const lang = @import("lang.zig");
const Op = lang.Op;
const Value = lang.Value;
const Ref = lang.Ref;
const RegRef = lang.RegRef;
const Gc = @import("gc.zig").Gc;

pub const Vm = struct {
    /// Instruction pointer
    ip: usize,
    call_stack: CallStack,
    gc: Gc,
    repl: bool,
    result: ?Ref = null,

    errors: lang.Error.List,

    const CallStack = std.SegmentedList(FunctionFrame, 16);

    const FunctionFrame = struct {
        return_ip: ?usize,
        result_reg: u8,
    };

    pub const Error = error{
        RuntimeError,
        MalformedByteCode,

        // TODO remove possibility
        Unimplemented,
    } || Allocator.Error;

    pub fn init(allocator: *Allocator, repl: bool) Vm {
        return Vm{
            .ip = 0,
            .gc = Gc.init(allocator),
            .call_stack = CallStack.init(allocator),
            .repl = repl,
            .errors = lang.Error.List.init(allocator),
        };
    }

    pub fn deinit(vm: *Vm) void {
        vm.call_stack.deinit();
        vm.errors.deinit();
        vm.gc.deinit();
    }

    // TODO some safety
    // TODO rename to step and execute 1 instruction
    pub fn exec(vm: *Vm, module: *lang.Module) Error!void {
        // TODO
        const stack = vm.gc.stack.toSlice();
        try vm.call_stack.push(.{
            .return_ip = null,
            .result_reg = 0,
        });
        defer _ = vm.call_stack.pop();
        while (vm.ip < module.code.len) {
            const op = @intToEnum(Op, vm.getVal(module, u8));
            switch (op) {
                .ConstInt8 => {
                    const A = vm.getVal(module, RegRef);
                    const val = vm.getVal(module, i8);

                    const ref = try vm.gc.alloc();
                    ref.value.?.* = .{
                        .kind = .{
                            .Int = val,
                        },
                    };
                    stack[A] = ref;
                },
                .ConstInt32 => {
                    const A = vm.getVal(module, RegRef);
                    const val = vm.getVal(module, i32);

                    const ref = try vm.gc.alloc();
                    ref.value.?.* = .{
                        .kind = .{
                            .Int = val,
                        },
                    };
                    stack[A] = ref;
                },
                .ConstInt64 => {
                    const A = vm.getVal(module, RegRef);
                    const val = vm.getVal(module, i64);

                    const ref = try vm.gc.alloc();
                    ref.value.?.* = .{
                        .kind = .{
                            .Int = val,
                        },
                    };
                    stack[A] = ref;
                },
                .ConstNum => {
                    const A = vm.getVal(module, RegRef);
                    const val = vm.getVal(module, f64);

                    const ref = try vm.gc.alloc();
                    ref.value.?.* = .{
                        .kind = .{
                            .Num = val,
                        },
                    };
                    stack[A] = ref;
                },
                .ConstPrimitive => {
                    const A = vm.getVal(module, RegRef);
                    const val = vm.getVal(module, u8);

                    if (val == 0) {
                        stack[A].value.? = &Value.None;
                    } else {
                        stack[A].value = if (val == 2) &Value.True else &Value.False;
                    }
                },
                .Add => {
                    const A = vm.getVal(module, RegRef);
                    const B_val = try vm.getNumeric(module);
                    const C_val = try vm.getNumeric(module);

                    // TODO check numeric
                    const ref = try vm.gc.alloc();
                    ref.value.?.* = .{
                        .kind = .{
                            .Int = B_val.kind.Int + C_val.kind.Int,
                        },
                    };
                    stack[A] = ref;
                },
                .Sub => {
                    const A = vm.getVal(module, RegRef);
                    const B_val = try vm.getNumeric(module);
                    const C_val = try vm.getNumeric(module);

                    // TODO check numeric
                    const ref = try vm.gc.alloc();
                    ref.value.?.* = .{
                        .kind = .{
                            .Int = B_val.kind.Int - C_val.kind.Int,
                        },
                    };
                    stack[A] = ref;
                },
                .Mul => {
                    const A = vm.getVal(module, RegRef);
                    const B_val = try vm.getNumeric(module);
                    const C_val = try vm.getNumeric(module);

                    // TODO check numeric
                    const ref = try vm.gc.alloc();
                    ref.value.?.* = .{
                        .kind = .{
                            .Int = B_val.kind.Int * C_val.kind.Int,
                        },
                    };
                    stack[A] = ref;
                },
                .Pow => {
                    const A = vm.getVal(module, RegRef);
                    const B_val = try vm.getNumeric(module);
                    const C_val = try vm.getNumeric(module);

                    // TODO check numeric
                    const ref = try vm.gc.alloc();
                    ref.value.?.* = .{
                        .kind = .{
                            .Int = std.math.powi(i64, B_val.kind.Int, C_val.kind.Int) catch @panic("TODO: overflow"),
                        },
                    };
                    stack[A] = ref;
                },
                .DivFloor => {
                    const A = vm.getVal(module, RegRef);
                    const B_val = try vm.getNumeric(module);
                    const C_val = try vm.getNumeric(module);

                    // TODO check numeric
                    const ref = try vm.gc.alloc();
                    ref.value.?.* = .{
                        .kind = .{
                            .Int = @divFloor(B_val.kind.Int, C_val.kind.Int),
                        },
                    };
                    stack[A] = ref;
                },
                .Move => {
                    const A = vm.getVal(module, RegRef);
                    const B = vm.getVal(module, RegRef);
                    stack[A] = stack[B];
                },
                .DirectAdd => {
                    const A_val = try vm.getNumeric(module);
                    const B_val = try vm.getNumeric(module);

                    // TODO check numeric
                    A_val.kind.Int += B_val.kind.Int;
                },
                .DirectSub => {
                    const A_val = try vm.getNumeric(module);
                    const B_val = try vm.getNumeric(module);

                    // TODO check numeric
                    A_val.kind.Int -= B_val.kind.Int;
                },
                .DirectMul => {
                    const A_val = try vm.getNumeric(module);
                    const B_val = try vm.getNumeric(module);

                    // TODO check numeric
                    A_val.kind.Int *= B_val.kind.Int;
                },
                .DirectPow => {
                    const A_val = try vm.getNumeric(module);
                    const B_val = try vm.getNumeric(module);

                    // TODO check numeric
                    A_val.kind.Int = std.math.powi(i64, A_val.kind.Int, B_val.kind.Int) catch @panic("TODO: overflow");
                },
                .DirectDivFloor => {
                    const A_val = try vm.getNumeric(module);
                    const B_val = try vm.getNumeric(module);

                    // TODO check numeric
                    A_val.kind.Int = @divFloor(A_val.kind.Int, B_val.kind.Int);
                },
                .BoolNot => {
                    const A = vm.getVal(module, RegRef);
                    const B_val = try vm.getBool(module);

                    stack[A].value = if (B_val) &Value.False else &Value.True;
                },
                .BitNot => {
                    const A = vm.getVal(module, RegRef);
                    const B_val = try vm.getInt(module);

                    const ref = try vm.gc.alloc();
                    ref.value.?.* = .{
                        .kind = .{
                            .Int = ~B_val,
                        },
                    };
                    stack[A] = ref;
                },
                .Negate => {
                    const A = vm.getVal(module, RegRef);
                    const B_val = try vm.getNumeric(module);

                    // TODO check numeric
                    const ref = try vm.gc.alloc();
                    ref.value.?.* = .{
                        .kind = .{
                            .Int = -B_val.kind.Int,
                        },
                    };
                    stack[A] = ref;
                },
                .JumpFalse => {
                    const A_val = try vm.getBool(module);
                    const addr = vm.getVal(module, u32);

                    if (A_val == false) {
                        vm.ip += addr;
                    }
                },
                .Jump => {
                    const addr = vm.getVal(module, u32);
                    vm.ip += addr;
                },
                .Discard => {
                    const A = vm.getVal(module, RegRef);
                    if (vm.repl and vm.call_stack.len == 1) {
                        vm.result = stack[A];
                    } else {
                        const val = stack[A].value.?;
                        if (val.kind == .Error) {
                            // TODO error discarded
                        }
                        // val.deref();
                        return error.Unimplemented;
                    }
                },
                .BuildTuple => {
                    const A = vm.getVal(module, RegRef);
                    const args = vm.getVal(module, []align(1) const RegRef);

                    // TODO gc this
                    const vals = try vm.call_stack.allocator.alloc(Ref, args.len);
                    for (args) |a, i| {
                        vals[i] = stack[a];
                    }

                    const ref = try vm.gc.alloc();
                    ref.value.?.* = .{
                        .kind = .{
                            .Tuple = vals,
                        },
                    };
                    stack[A] = ref;
                },
                .Subscript => {
                    const A = vm.getVal(module, RegRef);
                    const B = vm.getVal(module, RegRef);
                    const C = vm.getVal(module, RegRef);

                    stack[A] = switch (stack[B].value.?.kind) {
                        .Tuple => |val| val[@intCast(u32, stack[C].value.?.kind.Int)],
                        else => @panic("TODO: subscript for more types"),
                    };
                },
                .As => {
                    const A = vm.getVal(module, RegRef);
                    const B = vm.getVal(module, RegRef);
                    const type_id = vm.getVal(module, Value.TypeId);

                    if (type_id == .None) {
                        stack[A].value.? = &Value.None;
                        continue;
                    }

                    const ref = try vm.gc.alloc();
                    ref.value.?.* = switch (type_id) {
                        .None => unreachable,
                        else => @panic("TODO more casts"),
                    };
                    stack[A] = ref;
                },
                .Is => {
                    const A = vm.getVal(module, RegRef);
                    const B = vm.getVal(module, RegRef);
                    const type_id = vm.getVal(module, Value.TypeId);

                    stack[A].value = if (stack[B].value.?.kind == type_id) &Value.True else &Value.False;
                },
                else => {
                    std.debug.warn("Unimplemented: {}\n", .{op});
                },
            }
        }
    }

    fn getVal(vm: *Vm, module: *lang.Module, comptime T: type) T {
        if (T == []align(1) const RegRef) {
            const len = vm.getVal(module, u16);
            const val = @ptrCast([*]align(1) const RegRef, module.code[vm.ip..].ptr);
            vm.ip += @sizeOf(RegRef) * len;
            return val[0..len];
        }
        const val = @ptrCast(*align(1) const T, module.code[vm.ip..].ptr).*;
        vm.ip += @sizeOf(T);
        return val;
    }

    fn getBool(vm: *Vm, module: *lang.Module) !bool {
        // TODO
        const stack = vm.gc.stack.toSlice();
        const val = stack[vm.getVal(module, RegRef)].value.?;

        if (val.kind != .Bool) {
            return vm.reportErr("expected a boolean");
        }
        return val.kind.Bool;
    }

    fn getInt(vm: *Vm, module: *lang.Module) !i64 {
        // TODO
        const stack = vm.gc.stack.toSlice();
        const val = stack[vm.getVal(module, RegRef)].value.?;

        if (val.kind != .Int) {
            return vm.reportErr("expected an integer");
        }
        return val.kind.Int;
    }

    fn getNumeric(vm: *Vm, module: *lang.Module) !*Value {
        // TODO
        const stack = vm.gc.stack.toSlice();
        const val = stack[vm.getVal(module, RegRef)].value.?;

        if (val.kind != .Int and val.kind != .Num) {
            return vm.reportErr("expected a number");
        }
        return val;
    }

    fn reportErr(vm: *Vm, msg: []const u8) Error {
        try vm.errors.push(.{
            .msg = msg,
            .kind = .Error,
            .index = 0, // TODO debug info
        });
        while (vm.call_stack.pop()) |some| {
            if (vm.call_stack.len == 0) break;
            try vm.errors.push(.{
                .msg = "called here",
                .kind = .Trace,
                .index = 0, // TODO debug info
            });
        }
        return error.RuntimeError;
    }
};
