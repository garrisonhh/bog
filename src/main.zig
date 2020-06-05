const std = @import("std");
const process = std.process;
const mem = std.mem;
const bog = @import("bog.zig");
const repl = bog.repl;

const is_debug = @import("builtin").mode == .Debug;

pub fn main() !void {
    const alloc = std.heap.c_allocator;

    const args = try process.argsAlloc(alloc);
    defer process.argsFree(alloc, args);
    if (args.len > 1) {
        if (mem.eql(u8, args[1], "fmt")) {
            return fmt(alloc, args[2..]);
        }
        if (mem.eql(u8, args[1], "help") or mem.eql(u8, args[1], "--help")) {
            return help();
        }
        if (is_debug) {
            if (mem.eql(u8, args[1], "debug:dump")) {
                return debugDump(alloc, args[2..]);
            }
            if (mem.eql(u8, args[1], "debug:tokens")) {
                return debugTokens(alloc, args[2..]);
            }
            if (mem.eql(u8, args[1], "debug:write")) {
                return debugWrite(alloc, args[2..]);
            }
            if (mem.eql(u8, args[1], "debug:read")) {
                return debugRead(alloc, args[2..]);
            }
        }
        if (!mem.startsWith(u8, "-", args[1])) {
            return run(alloc, args[1..]);
        }
    }

    const in = std.io.bufferedInStream(std.io.getStdIn().inStream()).inStream();
    var stdout = std.io.getStdOut().outStream();

    try repl.run(alloc, in, stdout);
}

const usage =
    \\usage: bog [command] [options] [-- [args]]
    \\
    \\Commands:
    \\
    \\  fmt        [source]      Parse file and render it
    \\  run        [source]      Run file
    \\
    \\
;

fn help() !void {
    const stdout = &std.io.getStdOut().outStream();
    try stdout.writeAll(usage);
    process.exit(0);
}

fn run(alloc: *std.mem.Allocator, args: [][]const u8) !void {
    std.debug.assert(args.len > 0);
    const file_name = args[0];

    var vm = bog.Vm.init(alloc, .{ .import_files = true });
    defer vm.deinit();
    try bog.std.registerAll(&vm.native_registry);

    const source = std.fs.cwd().readFileAlloc(alloc, file_name, 1024 * 1024) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => |err| {
            printAndExit("unable to open '{}': {}", .{ file_name, err });
        },
    };
    defer alloc.free(source);

    var module = bog.Module.read(source) catch |e| switch (e) {
        // not a bog bytecode file
        error.InvalidMagic => null,
        else => |err| printAndExit("cannot execute file '{}': {}", .{ file_name, err }),
    };

    // TODO this doesn't cast nicely for some reason
    const res_with_err = (if (module) |*some| blk: {
        vm.ip = some.entry;
        break :blk vm.exec(some);
    } else
        vm.run(source));
    const res = res_with_err catch |e| switch (e) {
        error.TokenizeError, error.ParseError, error.CompileError, error.RuntimeError => printErrorsAndExit(&vm.errors, source),
        error.MalformedByteCode => if (is_debug) @panic("malformed") else printAndExit("attempted to execute invalid bytecode", .{}),
        error.OutOfMemory => return error.OutOfMemory,
    };

    switch (res.*) {
        .int => |int| {
            if (int >= 0 and int < std.math.maxInt(u8)) {
                process.exit(@intCast(u8, int));
            } else {
                printAndExit("invalid exit code: {}", .{int});
            }
        },
        .err => |err| {
            const stderr = std.io.getStdErr().outStream();
            try stderr.writeAll("script exited with error: ");
            try err.dump(stderr, 4);
            try stderr.writeAll("\n");
            process.exit(1);
        },
        .none => {},
        else => printAndExit("invalid return type '{}'", .{@tagName(res.*)}),
    }
}

const usage_fmt =
    \\usage: bog fmt [file]...
    \\
    \\   Formats the input files.
    \\
;

fn fmt(alloc: *std.mem.Allocator, args: [][]const u8) !void {
    if (args.len == 0) {
        printAndExit(usage_fmt, .{});
    }
    // TODO handle dirs
    const source = std.fs.cwd().readFileAlloc(alloc, args[0], 1024 * 1024) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.IsDir => printAndExit("TODO fmt dirs", .{}),
        else => |err| {
            printAndExit("unable to open '{}': {}", .{ args[0], err });
        },
    };
    defer alloc.free(source);

    var errors = bog.Errors.init(alloc);
    defer errors.deinit();

    var tree = bog.parse(alloc, source, &errors) catch |e| switch (e) {
        error.TokenizeError, error.ParseError => printErrorsAndExit(&errors, source),
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer tree.deinit();

    const file = try std.fs.cwd().createFile(args[0], .{});
    defer file.close();

    try tree.render(file.outStream());
}

fn printErrorsAndExit(errors: *bog.Errors, source: []const u8) noreturn {
    errors.render(source, std.io.getStdErr().outStream()) catch {};
    process.exit(1);
}

fn printAndExit(comptime msg: []const u8, args: var) noreturn {
    std.io.getStdErr().outStream().print(msg ++ "\n", args) catch {};
    process.exit(1);
}

fn debugDump(alloc: *std.mem.Allocator, args: [][]const u8) !void {
    if (args.len != 1) {
        printAndExit("expected one argument", .{});
    }
    const source = std.fs.cwd().readFileAlloc(alloc, args[0], 1024 * 1024) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => |err| {
            printAndExit("unable to open '{}': {}", .{ args[0], err });
        },
    };
    defer alloc.free(source);

    var errors = bog.Errors.init(alloc);
    defer errors.deinit();

    var module = bog.compile(alloc, source, &errors) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.TokenizeError, error.ParseError, error.CompileError => {
            try errors.render(source, std.io.getStdErr().outStream());
            process.exit(1);
        },
    };
    defer module.deinit(alloc);

    try module.dump(alloc, std.io.getStdOut().outStream());
}

fn debugTokens(alloc: *std.mem.Allocator, args: [][]const u8) !void {
    if (args.len != 1) {
        printAndExit("expected one argument", .{});
    }
    const source = std.fs.cwd().readFileAlloc(alloc, args[0], 1024 * 1024) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => |err| {
            printAndExit("unable to open '{}': {}", .{ args[0], err });
        },
    };
    defer alloc.free(source);

    var tree = bog.Tree{
        .tokens = bog.Token.List.init(alloc),
        .source = source,
        .nodes = undefined,
        .arena_allocator = undefined,
    };
    defer tree.tokens.deinit();

    var errors = bog.Errors.init(alloc);
    defer errors.deinit();

    bog.tokenize(&tree, &errors) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.TokenizeError => {
            try errors.render(source, std.io.getStdErr().outStream());
            process.exit(1);
        },
    };

    const stream = std.io.getStdOut().outStream();
    var it = tree.tokens.iterator(0);
    while (it.next()) |tok| {
        switch (tok.id) {
            .Nl, .End, .Begin => try stream.print("{}\n", .{@tagName(tok.id)}),
            else => try stream.print("{} |{}|\n", .{ @tagName(tok.id), source[tok.start..tok.end] }),
        }
    }
}

fn debugWrite(alloc: *std.mem.Allocator, args: [][]const u8) !void {
    if (args.len != 2) {
        printAndExit("expected one argument", .{});
    }
    const source = std.fs.cwd().readFileAlloc(alloc, args[0], 1024 * 1024) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => |err| {
            printAndExit("unable to open '{}': {}", .{ args[0], err });
        },
    };
    defer alloc.free(source);

    var errors = bog.Errors.init(alloc);
    defer errors.deinit();

    var module = bog.compile(alloc, source, &errors) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.TokenizeError, error.ParseError, error.CompileError => {
            try errors.render(source, std.io.getStdErr().outStream());
            process.exit(1);
        },
    };
    defer module.deinit(alloc);

    const file = try std.fs.cwd().createFile(args[1], .{});
    defer file.close();

    try module.write(file.outStream());
}

fn debugRead(alloc: *std.mem.Allocator, args: [][]const u8) !void {
    if (args.len != 1) {
        printAndExit("expected one argument", .{});
    }
    const source = std.fs.cwd().readFileAlloc(alloc, args[0], 1024 * 1024) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => |err| {
            printAndExit("unable to open '{}': {}", .{ args[0], err });
        },
    };
    defer alloc.free(source);

    const module = try bog.Module.read(source);

    try module.dump(alloc, std.io.getStdOut().outStream());
}

comptime {
    _ = @import("tokenizer.zig");
    _ = @import("value.zig");
}
