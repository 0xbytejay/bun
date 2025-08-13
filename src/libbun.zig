const std = @import("std");
const builtin = @import("builtin");
const bun = @import("bun");
const Output = bun.Output;
const Environment = bun.Environment;
// pub const RunCommand = @import("./cli/run_command.zig").RunCommand;

pub const panic = bun.crash_handler.panic;
pub const std_options = std.Options{
    .enable_segfault_handler = false,
};

pub const io_mode = .blocking;

comptime {
    bun.assert(builtin.target.cpu.arch.endian() == .little);
}

extern fn bun_warn_avx_missing(url: [*:0]const u8) void;

pub extern "c" var _environ: ?*anyopaque;
pub extern "c" var environ: ?*anyopaque;

const logger = bun.logger;

export fn run_js_with_bun() void {
    bun.crash_handler.init();

    if (Environment.isPosix) {
        var act: std.posix.Sigaction = .{
            .handler = .{ .handler = std.posix.SIG.IGN },
            .mask = std.posix.empty_sigset,
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.PIPE, &act, null);
        std.posix.sigaction(std.posix.SIG.XFSZ, &act, null);
    }

    if (Environment.isDebug) {
        bun.debug_allocator_data.backing = .init;
    }

    // This should appear before we make any calls at all to libuv.
    // So it's safest to put it very early in the main function.
    if (Environment.isWindows) {
        _ = bun.windows.libuv.uv_replace_allocator(
            &bun.Mimalloc.mi_malloc,
            &bun.Mimalloc.mi_realloc,
            &bun.Mimalloc.mi_calloc,
            &bun.Mimalloc.mi_free,
        );
        environ = @ptrCast(std.os.environ.ptr);
        _environ = @ptrCast(std.os.environ.ptr);
    }

    bun.start_time = std.time.nanoTimestamp();

    Output.Source.Stdio.init();

    bun.StackCheck.configureThread();

    std.debug.print("Start! \n", .{});

    var log_: logger.Log = logger.Log.init(bun.default_allocator);

    const result = bun.cli.Command.init(bun.default_allocator, &log_, .RunCommand);
    if (result) |ctx| {
        ctx.args.target = .bun;
        _ = bun.cli.RunCommand.zigbootAndHandleError(ctx, "/root/dev/bun-bun-v1.2.19/go_demo/index.js", .js);
    } else |err| {
        std.debug.print("Init Context Failed: {}\n", .{err});
    }

    // bun.CLI.Cli.start(bun.default_allocator);
    // bun.Global.exit(0);
}

pub export fn Bun__panic(msg: [*]const u8, len: usize) noreturn {
    Output.panic("{s}", .{msg[0..len]});
}

// -- Zig Standard Library Additions --
pub fn copyForwards(comptime T: type, dest: []T, source: []const T) void {
    if (source.len == 0) {
        return;
    }
    bun.copy(T, dest[0..source.len], source);
}
pub fn copyBackwards(comptime T: type, dest: []T, source: []const T) void {
    if (source.len == 0) {
        return;
    }
    bun.copy(T, dest[0..source.len], source);
}
pub fn eqlBytes(src: []const u8, dest: []const u8) bool {
    return bun.c.memcmp(src.ptr, dest.ptr, src.len) == 0;
}
// -- End Zig Standard Library Additions --
