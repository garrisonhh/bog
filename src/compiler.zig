const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const assert = std.debug.assert;
const lang = @import("lang.zig");
const TypeId = lang.Value.TypeId;
const Node = lang.Node;
const Tree = lang.Tree;
const TokenList = lang.Token.List;
const TokenIndex = lang.Token.Index;
const RegRef = lang.RegRef;

pub const Error = error{CompileError} || Allocator.Error;

pub const Compiler = struct {
    tree: *Tree,
    arena: *Allocator,
    root_scope: Scope.Fn,
    cur_scope: *Scope,
    used_regs: RegRef = 0,
    code: *Code,
    module_code: Code,
    strings: Code,

    pub const Code = std.ArrayList(u8);

    fn registerAlloc(self: *Compiler) RegRef {
        const reg = self.used_regs;
        self.used_regs += 1;
        return reg;
    }

    fn registerFree(self: *Compiler, reg: RegRef) void {
        if (reg == self.used_regs - 1) {
            self.used_regs -= 1;
        }
    }

    // TODO improve?
    fn emitInstruction_1(self: *Compiler, op: lang.Op, A: RegRef) !void {
        try self.code.append(@enumToInt(op));
        try self.code.appendSlice(@sliceToBytes(([_]RegRef{A})[0..]));
    }

    fn emitInstruction_1_1(self: *Compiler, op: lang.Op, A: RegRef, arg: var) !void {
        try self.code.append(@enumToInt(op));
        try self.code.appendSlice(@sliceToBytes(([_]RegRef{A})[0..]));
        try self.code.appendSlice(@sliceToBytes(([_]@TypeOf(arg){arg})[0..]));
    }

    fn emitInstruction_1_2(self: *Compiler, op: lang.Op, A: RegRef, arg: var, arg2: var) !void {
        try self.code.append(@enumToInt(op));
        try self.code.appendSlice(@sliceToBytes(([_]RegRef{A})[0..]));
        try self.code.appendSlice(@sliceToBytes(([_]@TypeOf(arg){arg})[0..]));
        try self.code.appendSlice(@sliceToBytes(([_]@TypeOf(arg2){arg2})[0..]));
    }

    fn emitInstruction_0_1(self: *Compiler, op: lang.Op, arg: var) !void {
        try self.code.append(@enumToInt(op));
        try self.code.appendSlice(@sliceToBytes(([_]@TypeOf(arg){arg})[0..]));
    }

    fn emitInstruction_2(self: *Compiler, op: lang.Op, A: RegRef, B: RegRef) !void {
        try self.code.append(@enumToInt(op));
        try self.code.appendSlice(@sliceToBytes(([_]RegRef{ A, B })[0..]));
    }

    fn emitInstruction_2_1(self: *Compiler, op: lang.Op, A: RegRef, B: RegRef, arg: var) !void {
        try self.code.append(@enumToInt(op));
        try self.code.appendSlice(@sliceToBytes(([_]RegRef{ A, B })[0..]));
        try self.code.appendSlice(@sliceToBytes(([_]@TypeOf(arg){arg})[0..]));
    }

    fn emitInstruction_3(self: *Compiler, op: lang.Op, A: RegRef, B: RegRef, C: RegRef) !void {
        try self.code.append(@enumToInt(op));
        try self.code.appendSlice(@sliceToBytes(([_]RegRef{ A, B, C })[0..]));
    }

    const Scope = struct {
        id: Id,
        parent: ?*Scope,
        syms: Symbol.List,

        const Id = enum {
            Fn,
            Loop,
            Block,
            Capture,
        };

        const Fn = struct {
            base: Scope,
            code: Code,
        };

        const Loop = struct {
            base: Scope,
            breaks: BreakList,
            cond_begin: u32,

            const BreakList = std.SegmentedList(u32, 4);
        };

        fn declSymbol(self: *Scope, sym: Symbol) !void {
            try self.syms.push(sym);
        }

        fn getSymbol(self: *Scope, name: []const u8) ?*Symbol {
            var it = self.syms.iterator(self.syms.len);
            while (it.prev()) |sym| {
                if (mem.eql(u8, sym.name, name)) {
                    return sym;
                }
            }
            // TODO self.parent
            if (self.parent) |some| {
                if (self.id == .Fn) @panic("TODO: closures");
                return some.getSymbol(name);
            }
            return null;
        }
    };

    pub const Symbol = struct {
        name: []const u8,
        reg: RegRef,
        mutable: bool,

        pub const List = std.SegmentedList(Symbol, 4);
    };

    const Value = union(enum) {
        /// result of continue, break, return and assignmnet; cannot exist at runtime
        Empty,
        Rt: RegRef,

        /// reference to a variable
        Ref: RegRef,

        None,
        Int: i64,
        Num: f64,
        Bool: bool,
        Str: []u8,

        fn isRt(val: Value) bool {
            return switch (val) {
                .Rt, .Ref => true,
                else => false,
            };
        }

        fn maybeRt(val: Value, self: *Compiler, res: Result) !Value {
            if (res == .Rt) {
                try self.makeRuntime(res.Rt, val);
                return res.toVal();
            }
            return val;
        }

        fn free(val: Value, self: *Compiler) void {
            if (val == .Rt) {
                self.registerFree(val.Rt);
            }
        }

        fn toRt(val: Value, self: *Compiler) !RegRef {
            switch (val) {
                .Rt, .Ref => |r| return r,
                .Empty => unreachable,
                else => {
                    const reg = self.registerAlloc();
                    try self.makeRuntime(reg, val);
                    return reg;
                },
            }
        }

        fn getRt(val: Value) RegRef {
            switch (val) {
                .Rt, .Ref => |r| return r,
                else => unreachable,
            }
        }

        fn getBool(val: Value, self: *Compiler, tok: TokenIndex) !bool {
            if (val != .Bool) {
                return self.reportErr("expected a boolean", tok);
            }
            return val.Bool;
        }

        fn getInt(val: Value, self: *Compiler, tok: TokenIndex) !i64 {
            if (val != .Int) {
                return self.reportErr("expected an integer", tok);
            }
            return val.Int;
        }

        fn getStr(val: Value, self: *Compiler, tok: TokenIndex) ![]const u8 {
            if (val != .Str) {
                return self.reportErr("expected a string", tok);
            }
            return val.Str;
        }

        fn checkNum(val: Value, self: *Compiler, tok: TokenIndex) !void {
            if (val != .Int and val != .Num) {
                return self.reportErr("expected a number", tok);
            }
            if (val == .Num) {
                return self.reportErr("TODO operations on real numbers", tok);
            }
        }
    };

    fn makeRuntime(self: *Compiler, res: RegRef, val: Value) Error!void {
        return switch (val) {
            .Empty => unreachable,
            .Ref, .Rt => |v| assert(v == res),
            .None => try self.emitInstruction_1_1(.ConstPrimitive, res, @as(u8, 0)),
            .Int => |v| if (v > std.math.minInt(i8) and v < std.math.maxInt(i8)) {
                try self.emitInstruction_1_1(.ConstInt8, res, @truncate(i8, v));
            } else if (v > std.math.minInt(i32) and v < std.math.maxInt(i32)) {
                try self.emitInstruction_1_1(.ConstInt32, res, @truncate(i32, v));
            } else {
                try self.emitInstruction_1_1(.ConstInt64, res, v);
            },
            .Num => |v| try self.emitInstruction_1_1(.ConstNum, res, v),
            .Bool => |v| try self.emitInstruction_1_1(.ConstPrimitive, res, @as(u8, @boolToInt(v)) + 1),
            .Str => |v| try self.emitInstruction_1_1(.ConstString, res, try self.putString(v)),
        };
    }

    fn putString(self: *Compiler, str: []const u8) !u32 {
        const len = @intCast(u32, self.strings.len);
        try self.strings.appendSlice(@sliceToBytes(([_]u32{@intCast(u32, str.len)})[0..]));
        try self.strings.appendSlice(str);
        return len;
    }

    const Result = union(enum) {
        /// A runtime value is expected
        Rt: RegRef,

        /// Something assignable is expected
        Lval: union(enum) {
            Const: RegRef,
            Let: RegRef,
            Assign: RegRef,
            AugAssign,
        },

        /// A value, runtime or constant, is expected
        Value,

        /// No value is expected if some is given it will be discarded
        Discard,

        fn toRt(res: Result, compiler: *Compiler) Result {
            return if (res == .Rt) res else Result{ .Rt = compiler.registerAlloc() };
        }

        fn toVal(res: Result) Value {
            return .{ .Rt = res.Rt };
        }

        fn notLval(res: Result, self: *Compiler, tok: TokenIndex) !void {
            if (res == .Lval) {
                return self.reportErr("invalid left hand side to assignment", tok);
            }
        }
    };

    pub fn compile(tree: *Tree, allocator: *Allocator) (Error || lang.Parser.Error)!lang.Module {
        const arena = &tree.arena_allocator.allocator;
        var compiler = Compiler{
            .tree = tree,
            .arena = arena,
            .root_scope = .{
                .base = .{
                    .id = .Fn,
                    .parent = null,
                    .syms = Symbol.List.init(arena),
                },
                .code = Code.init(arena),
            },
            .module_code = Code.init(allocator),
            .strings = Code.init(allocator),
            .code = undefined,
            .cur_scope = undefined,
        };
        compiler.code = &compiler.root_scope.code;
        compiler.cur_scope = &compiler.root_scope.base;

        var it = tree.nodes.iterator(0);
        while (it.next()) |n| {
            try compiler.addLineInfo(n.*);

            const last = it.peek() == null;
            const res = if (last)
                Result{ .Value = {} }
            else
                Result{ .Discard = {} };

            const val = try compiler.genNode(n.*, res);
            if (last) {
                const reg = try val.toRt(&compiler);
                defer compiler.registerFree(reg);

                try compiler.emitInstruction_1(.Return, reg);
            }
            if (val.isRt()) {
                const reg = val.getRt();
                defer val.free(&compiler);
                // discard unused runtime value
                try compiler.emitInstruction_1(.Discard, reg);
            }
        }

        const start_index = compiler.module_code.len;
        try compiler.module_code.appendSlice(compiler.code.toSliceConst());
        return lang.Module{
            .name = "",
            .code = compiler.module_code.toOwnedSlice(),
            .strings = compiler.strings.toOwnedSlice(),
            .start_index = @truncate(u32, start_index),
        };
    }

    pub fn compileRepl(self: *Compiler, node: *Node, module: *lang.Module) Error!usize {
        const start_len = self.module_code.len;
        try self.addLineInfo(node);
        const val = try self.genNode(node, .Discard);
        if (val.isRt() and val != .Empty) {
            const reg = try val.toRt(self);
            defer if (val != .Ref) self.registerFree(reg);

            try self.emitInstruction_1(.Discard, reg);
        }
        const final_len = self.module_code.len;
        try self.module_code.appendSlice(self.code.toSliceConst());

        module.code = self.module_code.toSliceConst();
        self.module_code.resize(final_len) catch unreachable;
        module.strings = self.strings.toSliceConst();
        return final_len - start_len;
    }

    fn genNode(self: *Compiler, node: *Node, res: Result) Error!Value {
        switch (node.id) {
            .Grouped => return self.genNode(@fieldParentPtr(Node.Grouped, "base", node).expr, res),
            .Literal => return self.genLiteral(@fieldParentPtr(Node.Literal, "base", node), res),
            .Block => return self.genBlock(@fieldParentPtr(Node.Block, "base", node), res),
            .Prefix => return self.genPrefix(@fieldParentPtr(Node.Prefix, "base", node), res),
            .Decl => return self.genDecl(@fieldParentPtr(Node.Decl, "base", node), res),
            .Identifier => return self.genIdentifier(@fieldParentPtr(Node.SingleToken, "base", node), res),
            .Infix => return self.genInfix(@fieldParentPtr(Node.Infix, "base", node), res),
            .If => return self.genIf(@fieldParentPtr(Node.If, "base", node), res),
            .Tuple => return self.genTupleList(@fieldParentPtr(Node.ListTupleMap, "base", node), res),
            .Discard => return self.reportErr("'_' can only be used to discard unwanted tuple/list items in destructuring assignment", node.firstToken()),
            .TypeInfix => return self.genTypeInfix(@fieldParentPtr(Node.TypeInfix, "base", node), res),
            .Fn => return self.genFn(@fieldParentPtr(Node.Fn, "base", node), res),
            .Suffix => return self.genSuffix(@fieldParentPtr(Node.Suffix, "base", node), res),
            .Error => return self.genError(@fieldParentPtr(Node.Error, "base", node), res),
            .While => return self.genWhile(@fieldParentPtr(Node.While, "base", node), res),
            .Jump => return self.genJump(@fieldParentPtr(Node.Jump, "base", node), res),
            .List => return self.genTupleList(@fieldParentPtr(Node.ListTupleMap, "base", node), res),
            .Catch => return self.genCatch(@fieldParentPtr(Node.Catch, "base", node), res),
            .Import => return self.genImport(@fieldParentPtr(Node.Import, "base", node), res),
            .Native => return self.genNative(@fieldParentPtr(Node.Native, "base", node), res),

            .Map => return self.reportErr("TODO: Map", node.firstToken()),
            .For => return self.reportErr("TODO: For", node.firstToken()),
            .Match => return self.reportErr("TODO: Match", node.firstToken()),
            .MapItem => return self.reportErr("TODO: MapItem", node.firstToken()),
            .MatchCatchAll => return self.reportErr("TODO: MatchCatchAll", node.firstToken()),
            .MatchLet => return self.reportErr("TODO: MatchLet", node.firstToken()),
            .MatchCase => return self.reportErr("TODO: MatchCase", node.firstToken()),
        }
    }

    fn genNodeNonEmpty(self: *Compiler, node: *Node, res: Result) Error!Value {
        const val = try self.genNode(node, res);

        if (val == .Empty) {
            return self.reportErr("expected a value", node.firstToken());
        }
        return val;
    }

    fn genTupleList(self: *Compiler, node: *Node.ListTupleMap, res: Result) Error!Value {
        if (res == .Lval) {
            switch (res.Lval) {
                .Const, .Let, .Assign => |reg| {
                    const index_reg = self.registerAlloc();
                    var sub_reg = self.registerAlloc();
                    var index_val = Value{
                        .Int = 0,
                    };

                    var it = node.values.iterator(0);
                    while (it.next()) |n| {
                        if (n.*.id == .Discard) {
                            index_val.Int += 1;
                            continue;
                        }
                        try self.makeRuntime(index_reg, index_val);
                        try self.emitInstruction_3(.Subscript, sub_reg, reg, index_reg);
                        const l_val = try self.genNode(n.*, switch (res.Lval) {
                            .Const => Result{ .Lval = .{ .Const = sub_reg } },
                            .Let => Result{ .Lval = .{ .Let = sub_reg } },
                            .Assign => Result{ .Lval = .{ .Assign = sub_reg } },
                            else => unreachable,
                        });
                        std.debug.assert(l_val == .Empty);
                        index_val.Int += 1;

                        // TODO this should probably be done in genIdentifier
                        if (it.peek() != null and res.Lval != .Assign) sub_reg = self.registerAlloc();
                    }
                    return Value.Empty;
                },
                .AugAssign => {
                    return self.reportErr("invalid left hand side to augmented assignment", node.r_tok);
                },
            }
        }
        const sub_res = res.toRt(self);
        const start = self.used_regs;
        self.used_regs += @intCast(u16, node.values.len);

        var it = node.values.iterator(0);
        var i = start;
        while (it.next()) |n| {
            _ = try self.genNode(n.*, Result{ .Rt = i });
            i += 1;
        }

        const command = switch (node.base.id) {
            .Tuple => .BuildTuple,
            .List => lang.Op.BuildList,
            else => unreachable,
        };
        try self.emitInstruction_2_1(command, sub_res.Rt, start, @intCast(u16, node.values.len));
        return sub_res.toVal();
    }

    fn genFn(self: *Compiler, node: *Node.Fn, res: Result) Error!Value {
        try res.notLval(self, node.fn_tok);

        if (node.params.len > std.math.maxInt(u8)) {
            return self.reportErr("too many parameters", node.fn_tok);
        }

        const old_used_regs = self.used_regs;
        defer self.used_regs = old_used_regs;

        var fn_scope = Scope.Fn{
            .base = .{
                .id = .Block,
                .parent = self.cur_scope,
                .syms = Symbol.List.init(self.arena),
            },
            .code = try Code.initCapacity(self.arena, 256),
        };
        defer fn_scope.code.deinit();
        self.cur_scope = &fn_scope.base;
        defer self.cur_scope = fn_scope.base.parent.?;

        // function body is emitted to a new arraylist and finally added to module_code
        const old_code = self.code;
        self.code = &fn_scope.code;

        // destructure parameters
        self.used_regs = @truncate(u16, node.params.len);
        var it = node.params.iterator(0);
        var i: RegRef = 0;
        while (it.next()) |n| {
            const param_res = try self.genNode(n.*, Result{
                .Lval = .{
                    .Let = i,
                },
            });
            std.debug.assert(param_res == .Empty);
            i += 1;
        }

        // gen body and return result
        const sub_res = res.toRt(self);
        try self.addLineInfo(node.body);
        const body_val = try self.genNode(node.body, .Value);
        // TODO if body_val == .Empty because last instruction was a return
        // then this return is not necessary
        if (body_val == .Empty or body_val == .None) {
            try self.code.append(@enumToInt(lang.Op.ReturnNone));
        } else {
            const reg = try body_val.toRt(self);
            defer body_val.free(self);

            try self.emitInstruction_1(.Return, reg);
        }

        self.code = old_code;
        try self.emitInstruction_1_2(
            .BuildFn,
            sub_res.Rt,
            @truncate(u8, node.params.len),
            @truncate(u32, self.module_code.len),
        );
        try self.module_code.appendSlice(fn_scope.code.toSlice());
        return sub_res.toVal();
    }

    fn genBlock(self: *Compiler, node: *Node.Block, res: Result) Error!Value {
        try res.notLval(self, node.stmts.at(0).*.firstToken());
        var block_scope = Scope{
            .id = .Block,
            .parent = self.cur_scope,
            .syms = Symbol.List.init(self.arena),
        };
        self.cur_scope = &block_scope;
        defer self.cur_scope = block_scope.parent.?;

        var it = node.stmts.iterator(0);
        while (it.next()) |n| {
            try self.addLineInfo(n.*);

            // return value of last instruction if it is not discarded
            if (it.peek() == null and res != .Discard) {
                return self.genNode(n.*, res);
            }

            const val = try self.genNode(n.*, .Discard);
            if (val.isRt()) {
                const reg = val.getRt();
                defer val.free(self);

                // discard unused runtime value
                try self.emitInstruction_1(.Discard, reg);
            }
        }
        return Value{ .Empty = {} };
    }

    fn genIf(self: *Compiler, node: *Node.If, res: Result) Error!Value {
        try res.notLval(self, node.if_tok);

        if (node.capture) |some| return self.reportErr("TODO if let", some.firstToken());

        const cond_val = try self.genNodeNonEmpty(node.cond, .Value);
        if (!cond_val.isRt()) {
            const bool_val = try cond_val.getBool(self, node.cond.firstToken());

            if (bool_val) {
                return self.genNode(node.if_body, res);
            } else if (node.else_body) |some| {
                return self.genNode(some, res);
            }

            const res_val = Value{ .None = {} };
            if (res == .Rt) {
                try self.makeRuntime(res.Rt, res_val);
                return Value{ .Rt = res.Rt };
            } else return res_val;
        }
        const sub_res = switch (res) {
            .Rt, .Discard => res,
            else => Result{
                .Rt = self.registerAlloc(),
            },
        };

        // jump past if_body if cond == false
        try self.emitInstruction_1_1(.JumpFalse, cond_val.getRt(), @as(u32, 0));
        const addr = self.code.len;
        const if_val = try self.genNode(node.if_body, sub_res);
        if (sub_res != .Rt and if_val.isRt()) {
            try self.emitInstruction_1(.Discard, if_val.getRt());
        }

        // jump past else_body since if_body was executed
        try self.emitInstruction_0_1(.Jump, @as(u32, 0));
        const addr2 = self.code.len;

        @ptrCast(*align(1) u32, self.code.toSlice()[addr - @sizeOf(u32) ..].ptr).* =
            @truncate(u32, self.code.len - addr);
        if (node.else_body) |some| {
            const else_val = try self.genNode(some, sub_res);
            if (sub_res != .Rt and else_val.isRt()) {
                try self.emitInstruction_1(.Discard, else_val.getRt());
            }
        } else if (sub_res == .Rt) {
            try self.emitInstruction_1_1(.ConstPrimitive, sub_res.Rt, @as(u8, 0));
        }

        @ptrCast(*align(1) u32, self.code.toSlice()[addr2 - @sizeOf(u32) ..].ptr).* =
            @truncate(u32, self.code.len - addr2);

        return if (sub_res == .Rt)
            Value{ .Rt = sub_res.Rt }
        else
            Value{ .Empty = {} };
    }

    fn genJump(self: *Compiler, node: *Node.Jump, res: Result) Error!Value {
        if (res != .Discard) {
            return self.reportErr("jump expression produces no value", node.tok);
        }
        if (node.op == .Return) {
            if (node.op.Return) |some| {
                const reg = self.registerAlloc();
                defer self.registerFree(reg);
                _ = try self.genNode(some, Result{ .Rt = reg });
                try self.emitInstruction_1(.Return, reg);
            } else {
                try self.code.append(@enumToInt(lang.Op.ReturnNone));
            }
            return Value{ .Empty = {} };
        }

        // find inner most loop
        const loop_scope = blk: {
            var scope = self.cur_scope;
            while (true) switch (scope.id) {
                .Fn => return self.reportErr(if (node.op == .Continue)
                    "continue outside of loop"
                else
                    "break outside of loop", node.tok),
                .Loop => break,
                else => scope = scope.parent.?,
            };
            break :blk @fieldParentPtr(Scope.Loop, "base", scope);
        };
        if (node.op == .Continue) {
            try self.emitInstruction_0_1(
                .Jump,
                @truncate(i32, -@intCast(isize, self.code.len - loop_scope.cond_begin)),
            );
        } else {
            try self.emitInstruction_0_1(.Jump, @as(u32, 0));
            try loop_scope.breaks.push(@intCast(u32, self.code.len));
        }

        return Value{ .Empty = {} };
    }

    fn genWhile(self: *Compiler, node: *Node.While, res: Result) Error!Value {
        try res.notLval(self, node.while_tok);

        var loop_scope = Scope.Loop{
            .base = .{
                .id = .Loop,
                .parent = self.cur_scope,
                .syms = Symbol.List.init(self.arena),
            },
            .breaks = Scope.Loop.BreakList.init(self.arena),
            .cond_begin = @intCast(u32, self.code.len),
        };
        self.cur_scope = &loop_scope.base;
        defer self.cur_scope = loop_scope.base.parent.?;

        if (node.capture) |some| return self.reportErr("TODO while let", some.firstToken());

        // beginning of condition
        var cond_jump: ?usize = null;

        const cond_val = try self.genNode(node.cond, .Value);
        if (cond_val.isRt()) {
            try self.emitInstruction_1_1(.JumpFalse, cond_val.getRt(), @as(u32, 0));
            cond_jump = self.code.len;
        } else {
            const bool_val = try cond_val.getBool(self, node.cond.firstToken());
            if (bool_val == false) {
                // never executed
                const res_val = Value{ .None = {} };
                if (res == .Rt) {
                    try self.makeRuntime(res.Rt, res_val);
                    return Value{ .Rt = res.Rt };
                } else return res_val;
            }
        }

        const sub_res = switch (res) {
            .Discard => res,
            else => return self.reportErr("TODO while expr", node.while_tok),
        };

        const body_val = try self.genNode(node.body, sub_res);
        if (sub_res != .Rt and body_val.isRt()) {
            try self.emitInstruction_1(.Discard, body_val.getRt());
        }

        // jump back to condition
        try self.emitInstruction_0_1(
            .Jump,
            @truncate(i32, -@intCast(isize, self.code.len + @sizeOf(lang.Op) + @sizeOf(u32) - loop_scope.cond_begin)),
        );

        // exit loop if cond == false
        if (cond_jump) |some| {
            @ptrCast(*align(1) u32, self.code.toSlice()[some - @sizeOf(u32) ..].ptr).* =
                @truncate(u32, self.code.len - some);
        }
        while (loop_scope.breaks.pop()) |some| {
            @ptrCast(*align(1) u32, self.code.toSlice()[some - @sizeOf(u32) ..].ptr).* =
                @truncate(u32, self.code.len - some);
        }

        return if (sub_res == .Rt)
            Value{ .Rt = sub_res.Rt }
        else
            Value{ .Empty = {} };
    }

    fn genCatch(self: *Compiler, node: *Node.Catch, res: Result) Error!Value {
        try res.notLval(self, node.tok);

        var sub_res = switch (res) {
            .Rt => res,
            .Discard => .Value,
            .Value => Result{ .Rt = self.registerAlloc() },
            .Lval => unreachable,
        };
        const l_val = try self.genNodeNonEmpty(node.lhs, sub_res);
        if (!l_val.isRt()) {
            return l_val;
        }
        sub_res = .{
            .Rt = try l_val.toRt(self),
        };

        try self.emitInstruction_1_1(.JumpNotError, sub_res.Rt, @as(u32, 0));
        const addr = self.code.len;

        if (node.capture) |some| {
            return self.reportErr("TODO: capture value", some.firstToken());
        }

        const r_val = try self.genNode(node.rhs, sub_res);

        @ptrCast(*align(1) u32, self.code.toSlice()[addr - @sizeOf(u32) ..].ptr).* =
            @truncate(u32, self.code.len - addr);
        return sub_res.toVal();
    }

    fn genPrefix(self: *Compiler, node: *Node.Prefix, res: Result) Error!Value {
        try res.notLval(self, node.tok);
        const r_val = try self.genNodeNonEmpty(node.rhs, .Value);

        if (r_val.isRt()) {
            const op_id = switch (node.op) {
                .BoolNot => .BoolNot,
                .BitNot => .BitNot,
                .Minus => .Negate,
                // TODO should unary + be a no-op
                .Plus => return r_val,
                .Try => lang.Op.Try,
            };
            defer r_val.free(self);

            const sub_res = res.toRt(self);
            try self.emitInstruction_2(op_id, sub_res.Rt, r_val.getRt());
            return sub_res.toVal();
        }
        const ret_val: Value = switch (node.op) {
            .BoolNot => .{ .Bool = !try r_val.getBool(self, node.rhs.firstToken()) },
            .BitNot => .{ .Int = ~try r_val.getInt(self, node.rhs.firstToken()) },
            .Minus => blk: {
                try r_val.checkNum(self, node.rhs.firstToken());
                if (r_val == .Int) {
                    // TODO check for overflow
                    break :blk Value{ .Int = -r_val.Int };
                } else {
                    break :blk Value{ .Num = -r_val.Num };
                }
            },
            .Plus => blk: {
                try r_val.checkNum(self, node.rhs.firstToken());
                break :blk r_val;
            },
            // errors are runtime only currently, so ret_val does not need to be checked
            // TODO should this be an error?
            .Try => r_val,
        };
        return ret_val.maybeRt(self, res);
    }

    fn genTypeInfix(self: *Compiler, node: *Node.TypeInfix, res: Result) Error!Value {
        try res.notLval(self, node.tok);
        const l_val = try self.genNodeNonEmpty(node.lhs, .Value);

        const type_str = self.tokenSlice(node.type_tok);
        const type_id = if (mem.eql(u8, type_str, "none"))
            .None
        else if (mem.eql(u8, type_str, "int"))
            .Int
        else if (mem.eql(u8, type_str, "num"))
            .Num
        else if (mem.eql(u8, type_str, "bool"))
            .Bool
        else if (mem.eql(u8, type_str, "str"))
            .Str
        else if (mem.eql(u8, type_str, "tuple"))
            .Tuple
        else if (mem.eql(u8, type_str, "map"))
            .Map
        else if (mem.eql(u8, type_str, "list"))
            .List
        else if (mem.eql(u8, type_str, "error"))
            .Error
        else if (mem.eql(u8, type_str, "range"))
            .Range
        else if (mem.eql(u8, type_str, "fn"))
            lang.Value.TypeId.Fn
        else
            return self.reportErr("expected a type name", node.type_tok);

        if (l_val.isRt()) {
            const sub_res = res.toRt(self);
            defer l_val.free(self);

            const op: lang.Op = if (node.op == .As) .As else .Is;
            try self.emitInstruction_2_1(op, sub_res.Rt, l_val.getRt(), type_id);
            return sub_res.toVal();
        }

        const ret_val = switch (node.op) {
            .As => switch (type_id) {
                .None => Value{ .None = {} },
                .Int => Value{
                    .Int = switch (l_val) {
                        .Int => |val| val,
                        .Num => |val| @floatToInt(i64, val),
                        .Bool => |val| @boolToInt(val),
                        // .Str => parseInt
                        else => return self.reportErr("invalid cast to int", node.lhs.firstToken()),
                    },
                },
                .Num => Value{
                    .Num = switch (l_val) {
                        .Num => |val| val,
                        .Int => |val| @intToFloat(f64, val),
                        .Bool => |val| @intToFloat(f64, @boolToInt(val)),
                        // .Str => parseNum
                        else => return self.reportErr("invalid cast to num", node.lhs.firstToken()),
                    },
                },
                .Bool => Value{
                    .Bool = switch (l_val) {
                        .Int => |val| val != 0,
                        .Num => |val| val != 0,
                        .Bool => |val| val,
                        .Str => |val| if (mem.eql(u8, val, "true"))
                            true
                        else if (mem.eql(u8, val, "false"))
                            false
                        else
                            return self.reportErr("cannot cast string to bool", node.lhs.firstToken()),
                        else => return self.reportErr("invalid cast to bool", node.lhs.firstToken()),
                    },
                },
                .Str => Value{
                    .Str = switch (l_val) {
                        .Int => |val| try std.fmt.allocPrint(self.arena, "{}", .{val}),
                        .Num => |val| try std.fmt.allocPrint(self.arena, "{d}", .{val}),
                        .Bool => |val| try mem.dupe(self.arena, u8, if (val) "true" else "false"),
                        .Str => |val| val,
                        else => return self.reportErr("invalid cast to string", node.lhs.firstToken()),
                    },
                },
                .Fn => return self.reportErr("cannot cast to function", node.type_tok),
                .Error => return self.reportErr("cannot cast to error", node.type_tok),
                .Range => return self.reportErr("cannot cast to range", node.type_tok),
                .Tuple, .Map, .List => return self.reportErr("TODO Rt casts", node.tok),
                _ => unreachable,
            },
            .Is => Value{
                .Bool = switch (type_id) {
                    .None => l_val == .None,
                    .Int => l_val == .Int,
                    .Num => l_val == .Num,
                    .Bool => l_val == .Bool,
                    .Str => l_val == .Str,
                    else => false,
                },
            },
        };

        return ret_val.maybeRt(self, res);
    }

    fn genSuffix(self: *Compiler, node: *Node.Suffix, res: Result) Error!Value {
        if (node.op == .Call) {
            try res.notLval(self, node.r_tok);
        }
        const l_val = try self.genNode(node.lhs, .Value);
        if (!l_val.isRt()) {
            return self.reportErr("Invalid left hand side to suffix op", node.lhs.firstToken());
        }
        switch (node.op) {
            .Call => |*args| {
                const len = if (args.len == 0) 1 else args.len;
                const arg_locs = try self.arena.alloc(RegRef, len);
                for (arg_locs) |*a| {
                    a.* = self.registerAlloc();
                }

                var i: u32 = 0;
                var it = args.iterator(0);
                while (it.next()) |n| {
                    _ = try self.genNode(n.*, Result{ .Rt = arg_locs[i] });
                    i += 1;
                }

                try self.emitInstruction_2_1(.Call, l_val.getRt(), arg_locs[0], @truncate(u16, args.len));
                if (res == .Rt) {
                    // TODO probably should handle this better
                    try self.emitInstruction_2(.Move, res.Rt, arg_locs[0]);
                    return Value{ .Rt = res.Rt };
                }
                return Value{ .Rt = arg_locs[0] };
            },
            .Member => return self.reportErr("TODO: member access", node.l_tok),
            .Subscript => |val| {
                const res_reg = switch (res) {
                    .Rt => |r| r,
                    .Lval => |l| switch (l) {
                        .Let, .Const => return self.reportErr("cannot declare to subscript", node.l_tok),
                        .AugAssign => self.registerAlloc(),
                        else => return self.reportErr("TODO: assign to subscript", node.l_tok),
                    },
                    .Discard, .Value => self.registerAlloc(),
                };

                const val_res = try self.genNodeNonEmpty(val, .Value);

                const reg = self.registerAlloc();
                defer self.registerFree(reg);
                try self.makeRuntime(reg, val_res);

                try self.emitInstruction_3(.Subscript, res_reg, l_val.getRt(), reg);
                return Value{ .Rt = res_reg };
            },
        }
    }

    fn genInfix(self: *Compiler, node: *Node.Infix, res: Result) Error!Value {
        try res.notLval(self, node.tok);
        switch (node.op) {
            .BoolOr,
            .BoolAnd,
            => {},

            .LessThan,
            .LessThanEqual,
            .GreaterThan,
            .GreaterThanEqual,
            .Equal,
            .NotEqual,
            .In,
            => return self.genComparisionInfix(node, res),

            .Range => {},

            .BitAnd,
            .BitOr,
            .BitXor,
            .LShift,
            .RShift,
            => {},

            .Add,
            .Sub,
            .Mul,
            .Div,
            .DivFloor,
            .Mod,
            .Pow,
            => return self.genNumericInfix(node, res),

            .Assign,
            .AddAssign,
            .SubAssign,
            .MulAssign,
            .PowAssign,
            .DivAssign,
            .DivFloorAssign,
            .ModAssign,
            .LShiftAssign,
            .RShfitAssign,
            .BitAndAssign,
            .BitOrAssign,
            .BitXOrAssign,
            => return self.genAssignInfix(node, res),
        }
        return self.reportErr("TODO more infix ops", node.tok);
    }

    fn genAssignInfix(self: *Compiler, node: *Node.Infix, res: Result) Error!Value {
        if (res == .Rt) {
            return self.reportErr("assignment produces no value", node.tok);
        }
        const reg = self.registerAlloc();
        defer self.registerFree(reg);
        const r_val = try self.genNodeNonEmpty(node.rhs, Result{ .Rt = reg });

        if (node.op == .Assign) {
            const l_val = try self.genNode(node.lhs, Result{ .Lval = .{ .Assign = reg } });
            std.debug.assert(l_val == .Empty);
            return l_val;
        }

        const l_val = try self.genNode(node.lhs, Result{ .Lval = .AugAssign });

        const op_id = switch (node.op) {
            .AddAssign => lang.Op.DirectAdd,
            .SubAssign => .DirectSub,
            .MulAssign => .DirectMul,
            .PowAssign => .DirectPow,
            .DivAssign => .DirectDiv,
            .DivFloorAssign => .DirectDivFloor,
            .ModAssign => .DirectMod,
            .LShiftAssign => .DirectLShift,
            .RShfitAssign => .DirectRShift,
            .BitAndAssign => .DirectBitAnd,
            .BitOrAssign => .DirectBitOr,
            .BitXOrAssign => .DirectBitXor,
            else => unreachable,
        };

        try self.emitInstruction_2(op_id, l_val.getRt(), r_val.getRt());
        return Value.Empty;
    }

    fn genNumericInfix(self: *Compiler, node: *Node.Infix, res: Result) Error!Value {
        var l_val = try self.genNodeNonEmpty(node.lhs, .Value);
        var r_val = try self.genNodeNonEmpty(node.rhs, .Value);

        if (r_val.isRt() or l_val.isRt()) {
            const sub_res = res.toRt(self);

            const l_reg = try l_val.toRt(self);
            const r_reg = try r_val.toRt(self);
            defer {
                r_val.free(self);
                l_val.free(self);
            }

            const op_id = switch (node.op) {
                .Add => .Add,
                .Sub => .Sub,
                .Mul => .Mul,
                .Div => .Div,
                .DivFloor => .DivFloor,
                .Mod => .Mod,
                .Pow => lang.Op.Pow,
                else => unreachable,
            };

            try self.emitInstruction_3(op_id, sub_res.Rt, l_reg, r_reg);
            return sub_res.toVal();
        }
        try r_val.checkNum(self, node.tok);
        try l_val.checkNum(self, node.tok);

        // TODO makeRuntime if overflow
        // TODO decay to numeric
        const ret_val = switch (node.op) {
            .Add => blk: {
                break :blk Value{ .Int = l_val.Int + r_val.Int };
            },
            .Sub => blk: {
                break :blk Value{ .Int = l_val.Int - r_val.Int };
            },
            .Mul => blk: {
                break :blk Value{ .Int = l_val.Int * r_val.Int };
            },
            .Div => blk: {
                return self.reportErr("TODO division", node.tok);
                // break :blk Value{ .Num = std.math.div(l_val.Int, r_val.Int) };
            },
            .DivFloor => blk: {
                break :blk Value{ .Int = @divFloor(l_val.Int, r_val.Int) };
            },
            .Mod => blk: {
                return self.reportErr("TODO modulo", node.tok);
                // break :blk Value{ .Int =std.math.rem(i64, l_val.Int, r_val.Int) catch @panic("TODO") };
            },
            .Pow => blk: {
                break :blk Value{
                    .Int = std.math.powi(i64, l_val.Int, r_val.Int) catch
                        return self.reportErr("TODO integer overflow", node.tok),
                };
            },
            else => unreachable,
        };

        return ret_val.maybeRt(self, res);
    }

    fn genComparisionInfix(self: *Compiler, node: *Node.Infix, res: Result) Error!Value {
        var l_val = try self.genNodeNonEmpty(node.lhs, .Value);
        var r_val = try self.genNodeNonEmpty(node.rhs, .Value);

        if (r_val.isRt() or l_val.isRt()) {
            const sub_res = res.toRt(self);

            const l_reg = try l_val.toRt(self);
            const r_reg = try r_val.toRt(self);
            defer {
                r_val.free(self);
                l_val.free(self);
            }

            const op_id = switch (node.op) {
                .LessThan => .LessThan,
                .LessThanEqual => .LessThanEqual,
                .GreaterThan => .GreaterThan,
                .GreaterThanEqual => .GreaterThanEqual,
                .Equal => .Equal,
                .NotEqual => .NotEqual,
                .In => lang.Op.In,
                else => unreachable,
            };
            try self.emitInstruction_3(op_id, sub_res.Rt, l_reg, r_reg);
            return sub_res.toVal();
        }

        // order comparisions are only allowed on numbers
        switch (node.op) {
            .In, .Equal, .NotEqual => {},
            else => {
                try l_val.checkNum(self, node.lhs.firstToken());
                try r_val.checkNum(self, node.rhs.firstToken());
            },
        }

        const ret_val: Value = switch (node.op) {
            .LessThan => .{ .Bool = l_val.Int < r_val.Int },
            .LessThanEqual => .{ .Bool = l_val.Int <= r_val.Int },
            .GreaterThan => .{ .Bool = l_val.Int > r_val.Int },
            .GreaterThanEqual => .{ .Bool = l_val.Int >= r_val.Int },
            .Equal, .NotEqual => blk: {
                const eql = switch (l_val) {
                    .None => |a_val| switch (r_val) {
                        .None => true,
                        else => false,
                    },
                    .Int => |a_val| switch (r_val) {
                        .Int => |b_val| a_val == b_val,
                        .Num => |b_val| @intToFloat(f64, a_val) == b_val,
                        else => false,
                    },
                    .Num => |a_val| switch (r_val) {
                        .Int => |b_val| a_val == @intToFloat(f64, b_val),
                        .Num => |b_val| a_val == b_val,
                        else => false,
                    },
                    .Bool => |a_val| switch (r_val) {
                        .Bool => |b_val| a_val == b_val,
                        else => false,
                    },
                    .Str => |a_val| switch (r_val) {
                        .Str => |b_val| mem.eql(u8, a_val, b_val),
                        else => false,
                    },
                    .Empty, .Rt, .Ref => unreachable,
                };
                // broken LLVM module found: Terminator found in the middle of a basic block!
                // break :blk Value{ .Bool = if (node.op == .Equal) eql else !eql };
                const copy = if (node.op == .Equal) eql else !eql;
                break :blk Value{ .Bool = copy };
            },
            .In => .{
                .Bool = mem.indexOf(
                    u8,
                    try l_val.getStr(self, node.lhs.firstToken()),
                    try r_val.getStr(self, node.rhs.firstToken()),
                ) != null,
            },
            else => unreachable,
        };
        return ret_val.maybeRt(self, res);
    }

    fn genDecl(self: *Compiler, node: *Node.Decl, res: Result) Error!Value {
        assert(res != .Lval);
        const r_loc = self.registerAlloc();
        assert((try self.genNode(node.value, Result{ .Rt = r_loc })).isRt());

        const lval_kind = if (self.tree.tokens.at(node.let_const).id == .Keyword_let)
            Result{ .Lval = .{ .Let = r_loc } }
        else
            Result{ .Lval = .{ .Const = r_loc } };

        assert((try self.genNode(node.capture, lval_kind)) == .Empty);
        return Value.Empty;
    }

    fn genIdentifier(self: *Compiler, node: *Node.SingleToken, res: Result) Error!Value {
        const name = self.tokenSlice(node.tok);
        if (res == .Lval) {
            switch (res.Lval) {
                .Let, .Const => |r| {
                    if (self.cur_scope.getSymbol(name)) |sym| {
                        return self.reportErr("redeclaration of identifier", node.tok);
                    }
                    // TODO this should copy r if r.refs > 1
                    try self.cur_scope.declSymbol(.{
                        .name = name,
                        .mutable = res.Lval == .Let,
                        .reg = r,
                    });
                    return Value.Empty;
                },
                .Assign => |r| {
                    if (self.cur_scope.getSymbol(name)) |sym| {
                        if (!sym.mutable) {
                            return self.reportErr("assignment to constant", node.tok);
                        }
                        // TODO this should copy r if r.refs > 1
                        // TODO this move can usually be avoided
                        try self.emitInstruction_2(.Move, sym.reg, r);
                        return Value.Empty;
                    }
                },
                .AugAssign => {
                    if (self.cur_scope.getSymbol(name)) |sym| {
                        if (!sym.mutable) {
                            return self.reportErr("assignment to constant", node.tok);
                        }
                        return Value{ .Ref = sym.reg };
                    }
                },
            }
        } else if (self.cur_scope.getSymbol(name)) |sym| {
            if (res == .Rt) {
                try self.emitInstruction_2(.Move, res.Rt, sym.reg);
                return res.toVal();
            }
            return Value{ .Ref = sym.reg };
        }
        return self.reportErr("use of undeclared identifier", node.tok);
    }

    fn genLiteral(self: *Compiler, node: *Node.Literal, res: Result) Error!Value {
        try res.notLval(self, node.tok);
        const ret_val: Value = switch (node.kind) {
            .Int => .{ .Int = try self.parseInt(node.tok) },
            .True => .{ .Bool = true },
            .False => .{ .Bool = false },
            .None => .None,
            .Str => .{ .Str = try self.parseStr(node.tok) },
            .Num => .{ .Num = self.parseNum(node.tok) },
        };
        return ret_val.maybeRt(self, res);
    }

    fn genImport(self: *Compiler, node: *Node.Import, res: Result) Error!Value {
        try res.notLval(self, node.tok);

        const sub_res = res.toRt(self);
        const str = try self.parseStr(node.str_tok);
        const str_loc = try self.putString(str);

        try self.emitInstruction_1_1(.Import, sub_res.Rt, str_loc);
        return sub_res.toVal();
    }

    fn genNative(self: *Compiler, node: *Node.Native, res: Result) Error!Value {
        try res.notLval(self, node.tok);

        const sub_res = res.toRt(self);
        const name = try self.parseStr(node.name_tok);
        const name_loc = try self.putString(name);
        if (node.lib_tok) |some| {
            const lib = try self.parseStr(some);
            const lib_loc = try self.putString(lib);

            try self.emitInstruction_1_2(.NativeExtern, sub_res.Rt, lib_loc, name_loc);
        } else {
            try self.emitInstruction_1_1(.Native, sub_res.Rt, name_loc);
        }

        return sub_res.toVal();
    }

    fn genError(self: *Compiler, node: *Node.Error, res: Result) Error!Value {
        try res.notLval(self, node.tok);
        const val = try self.genNodeNonEmpty(node.value, .Value);

        const sub_res = res.toRt(self);
        const reg = try val.toRt(self);
        defer val.free(self);

        try self.emitInstruction_2(.BuildError, sub_res.Rt, reg);
        return sub_res.toVal();
    }

    fn addLineInfo(self: *Compiler, node: *Node) !void {
        const token = node.firstToken();
        const tok = self.tree.tokens.at(token);

        try self.emitInstruction_0_1(.LineInfo, tok.start);
    }

    fn tokenSlice(self: *Compiler, token: TokenIndex) []const u8 {
        const tok = self.tree.tokens.at(token);
        return self.tree.source[tok.start..tok.end];
    }

    fn parseStr(self: *Compiler, tok: TokenIndex) ![]u8 {
        var slice = self.tokenSlice(tok);
        slice = slice[1 .. slice.len - 1];

        var buf = try self.arena.alloc(u8, slice.len);
        var slice_i: u32 = 0;
        var i: u32 = 0;
        while (slice_i < slice.len) : (slice_i += 1) {
            const c = slice[slice_i];
            switch (c) {
                '\\' => {
                    slice_i += 1;
                    buf[i] = switch (slice[slice_i]) {
                        '\\' => '\\',
                        'n' => '\n',
                        'r' => '\r',
                        't' => '\t',
                        '\'' => '\'',
                        '"' => '"',
                        'x', 'u' => return self.reportErr("TODO: more escape sequences", tok),
                        else => unreachable,
                    };
                },
                else => buf[i] = c,
            }
            i += 1;
        }
        return buf[0..i];
    }

    fn parseInt(self: *Compiler, tok: TokenIndex) !i64 {
        var buf = self.tokenSlice(tok);
        var radix: u8 = if (buf.len > 2) switch (buf[1]) {
            'x' => @as(u8, 16),
            'b' => 2,
            'o' => 8,
            else => 10,
        } else 10;
        if (radix != 10) buf = buf[2..];
        var x: i64 = 0;

        for (buf) |c| {
            const digit = switch (c) {
                '0'...'9' => c - '0',
                'A'...'Z' => c - 'A' + 10,
                'a'...'z' => c - 'a' + 10,
                '_' => continue,
                else => unreachable,
            };

            x = std.math.mul(i64, x, radix) catch
                return self.reportErr("TODO: bigint", tok);
            // why is this cast needed?
            x += @intCast(i32, digit);
        }

        return x;
    }

    fn parseNum(self: *Compiler, tok: TokenIndex) f64 {
        var buf: [256]u8 = undefined;
        const slice = self.tokenSlice(tok);

        var i: u32 = 0;
        for (slice) |c| {
            if (c != '_') {
                buf[i] = c;
                i += 1;
            }
        }

        return std.fmt.parseFloat(f64, buf[0..i]) catch unreachable;
    }

    fn reportErr(self: *Compiler, msg: []const u8, tok: TokenIndex) Error {
        try self.tree.errors.push(.{
            .msg = msg,
            .kind = .Error,
            .index = self.tree.tokens.at(tok).start,
        });
        return error.CompileError;
    }
};
