const std = @import("std");
const File = std.fs.File;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const bog = @import("bog.zig");
const Vm = bog.Vm;
const Errors = bog.Errors;
const linenoize = @import("linenoize");
const builtin = @import("builtin");

pub fn run(gpa: Allocator, in: File, out: File) !void {
    var repl: Repl = undefined;
    try repl.init(gpa);
    defer repl.deinit();

    const writer = out.writer();

    while (true) {
        defer {
            repl.arena.deinit();
            repl.arena = std.heap.ArenaAllocator.init(gpa);
        }
        repl.handleLine(in, out) catch |err| switch (err) {
            error.EndOfStream => return,
            error.TokenizeError, error.ParseError, error.CompileError => try repl.vm.errors.render(writer),
            error.FatalError => {
                repl.frame.stack.items[0] = bog.Value.Null;
                try repl.vm.errors.render(writer);
            },
            else => |e| return e,
        };
    }
}

pub const Repl = struct {
    buffer: ArrayList(u8),
    ln: linenoize.Linenoise,
    tokenizer: bog.Tokenizer,
    parser: bog.Parser,
    tree: bog.Tree,
    compiler: bog.Compiler,
    bytecode: bog.Bytecode,
    code: bog.Compiler.Code,
    arena: std.heap.ArenaAllocator,
    vm: Vm,
    frame: *Vm.Frame,

    const tokenize = @import("tokenizer.zig").tokenizeRepl;
    const parse = @import("parser.zig").parseRepl;
    const compile = @import("Compiler.zig").compileRepl;

    fn init(repl: *Repl, gpa: Allocator) !void {
        repl.buffer = try ArrayList(u8).initCapacity(gpa, std.mem.page_size);
        errdefer repl.buffer.deinit();

        if (builtin.os.tag != .windows) {
            repl.ln = linenoize.Linenoise.init(gpa);
        }

        repl.tokenizer = .{
            .errors = &repl.vm.errors,
            .path = "<stdin>",
            .it = .{
                .i = 0,
                .bytes = "",
            },
            .repl = true,
        };

        repl.parser = .{
            .errors = &repl.vm.errors,
            .source = "",
            .path = "<stdin>",
            .tok_ids = &.{},
            .tok_starts = &.{},
            .extra = std.ArrayList(bog.Node.Index).init(gpa),
            .node_buf = std.ArrayList(bog.Node.Index).init(gpa),
            .repl = true,
        };

        repl.compiler = bog.Compiler{
            .tree = &repl.tree,
            .errors = &repl.vm.errors,
            .gpa = gpa,
            .arena = repl.arena.allocator(),
            .code = &repl.code,
            .params = 1, // ans
        };
        errdefer repl.compiler.deinit();

        try repl.compiler.scopes.append(gpa, .{
            .symbol = .{
                .name = "ans",
                .ref = @intToEnum(bog.Bytecode.Ref, 0),
                .mut = false,
                .val = undefined,
            },
        });
        try repl.compiler.globals.append(gpa, .{
            .name = "ans",
            .ref = @intToEnum(bog.Bytecode.Ref, 0),
            .mut = false,
            .val = undefined,
        });
        repl.code = .{};
        // repl.bytecode is initialized by compileRepl

        repl.arena = std.heap.ArenaAllocator.init(gpa);
        errdefer repl.arena.deinit();

        repl.vm = Vm.init(gpa, .{ .repl = true, .import_files = true });
        errdefer repl.vm.deinit();
        try repl.vm.addStd();

        // set up base frame
        repl.frame = try gpa.create(Vm.Frame);
        repl.frame.* = .{
            .this = bog.Value.Null,
            .mod = &repl.bytecode,
            .body = &.{},
            .caller_frame = null,
            .module_frame = repl.frame,
            .captures = &.{},
            .params = 1,
        };

        try repl.frame.stack.append(gpa, bog.Value.Null);

        const frame_val = try repl.vm.gc.alloc();
        frame_val.* = .{ .frame = repl.frame };
        try repl.vm.gc.setBaseFrame(frame_val);
    }

    fn deinit(repl: *Repl) void {
        repl.vm.gc.clearBaseFrame();

        const gpa = repl.vm.gc.gpa;
        repl.buffer.deinit();
        repl.ln.deinit();
        repl.tokenizer.tokens.deinit(gpa);
        repl.parser.node_buf.deinit();
        repl.parser.extra.deinit();
        repl.parser.nodes.deinit(gpa);
        repl.compiler.deinit();
        repl.code.deinit(gpa);
        repl.arena.deinit();
        repl.vm.deinit();
        repl.* = undefined;
    }

    fn handleLine(repl: *Repl, in: File, out: File) !void {
        const buffer_start = repl.buffer.items.len;
        errdefer |e| if (e == error.CompileError) {
            repl.buffer.shrinkAndFree(buffer_start);
        };

        try repl.readLine(in, out, ">>> ");
        const node = while (true) {
            if (try repl.tokenize()) {
                if (repl.parse()) |some| {
                    break some orelse return;
                } else |err| switch (err) {
                    error.NeedInput => {},
                    else => |e| return e,
                }
            }

            try repl.readLine(in, out, "... ");
        } else unreachable;
        try repl.compile(node);

        const res = try repl.vm.run(repl.frame);
        repl.frame.stack.items[0] = res;
        if (res == bog.Value.Null) return;

        const writer = out.writer();
        try res.dump(writer, 2);
        try writer.writeByte('\n');
    }

    fn readLine(repl: *Repl, in: File, out: File, prompt: []const u8) !void {
        if (builtin.os.tag == .windows) {
            try out.writeAll(prompt);

            const line = try in.reader().readUntilDelimiterAlloc(repl.buffer.allocator, '\n', 1024);
            defer repl.buffer.allocator.free(line);

            try repl.buffer.appendSlice(line);
            try repl.buffer.append('\n');
            return;
        }
        if (linenoize.linenoiseRaw(&repl.ln, in, out, prompt)) |maybe_line| {
            const line = maybe_line orelse return error.EndOfStream;
            defer repl.ln.allocator.free(line);

            try repl.buffer.appendSlice(line);
            try repl.buffer.append('\n');

            try repl.ln.history.add(line);
        } else |err| {
            switch (err) {
                error.CtrlC => return error.EndOfStream,
                else => |e| return e,
            }
        }
    }
};
