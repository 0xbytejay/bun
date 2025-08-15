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

export fn VirtualMachine_getMainThreadVM() callconv(.C) ?*bun.CLI.BunJS.VirtualMachine {
    return bun.CLI.BunJS.VirtualMachine.getMainThreadVM();
}

export fn VirtualMachine_getMainThreadVMGlobalObject() callconv(.C) ?*bun.CLI.BunJS.JSC.JSGlobalObject {
    if (bun.CLI.BunJS.VirtualMachine.getMainThreadVM()) |vm| {
        return vm.global;
    }
    return null;
}

pub const JSValueResult = extern struct {
    value: bun.CLI.BunJS.JSC.JSValue = bun.CLI.BunJS.JSC.JSValue.zero, // JSValue or error code
    is_err: bool = false, // true if value represents an error, false if it is a valid JSValue
};

export fn JSGlobalObject_toJSValue(globalThis: ?*bun.CLI.BunJS.JSC.JSGlobalObject) callconv(.C) JSValueResult {
    if (globalThis) |_globalThis| {
        return JSValueResult{ .value = _globalThis.toJSValue() };
    }
    return JSValueResult{ .is_err = true, .value = bun.CLI.BunJS.JSC.JSValue.zero };
}

export fn JSValue_get(globalThis: ?*bun.CLI.BunJS.JSC.JSGlobalObject, jsValue: bun.CLI.BunJS.JSC.JSValue, property: [*:0]const u8) callconv(.C) JSValueResult {
    if (globalThis) |_globalThis| {
        const value = jsValue.get(_globalThis, std.mem.span(property)) catch |err| {
            return switch (err) {
                error.JSError => JSValueResult{ .value = @enumFromInt(501), .is_err = true },
                error.OutOfMemory => JSValueResult{ .value = @enumFromInt(502), .is_err = true },
            };
        } orelse {
            return JSValueResult{ .is_err = true, .value = .null };
        };

        return JSValueResult{ .value = value, .is_err = false };
    }
    return JSValueResult{ .is_err = true, .value = bun.CLI.BunJS.JSC.JSValue.zero };
}

export fn JSValue_toString(globalThis: ?*bun.CLI.BunJS.JSC.JSGlobalObject, jsValue: bun.CLI.BunJS.JSC.JSValue) callconv(.C) ?*c_char {
    if (globalThis) |_globalThis| {
        const zig_str = jsValue.toBunString(_globalThis) catch {
            return null;
        };

        defer zig_str.deref();

        const utf8 = zig_str.encode(bun.CLI.BunJS.JSC.Node.Encoding.utf8);

        const allocator = std.heap.c_allocator;
        const s = allocator.alloc(u8, utf8.len) catch {
            return null;
        };
        _ = std.mem.copyForwards(u8, s, utf8);
        return @ptrCast(s);
    }
    return null;
}

export fn JSValue_call(globalThis: ?*bun.CLI.BunJS.JSC.JSGlobalObject, thisValue: bun.CLI.BunJS.JSC.JSValue, callFunc: bun.CLI.BunJS.JSC.JSValue, args_ptr: ?*[3]usize) callconv(.C) ?*c_char {
    if (globalThis) |_globalThis| {
        var args_data: []bun.CLI.BunJS.JSC.JSValue = &.{};

        if (args_ptr) |_args_ptr| {
            const args_data_ptr: [*]bun.CLI.BunJS.JSC.JSValue = @ptrFromInt(_args_ptr[0]);
            const args_len = _args_ptr[1]; // length
            args_data = args_data_ptr[0..args_len];
        }
        // FIXME: Random Crash
        _ = callFunc.call(_globalThis, thisValue, &.{}) catch |err| {
            std.debug.print("call func failed: {}", .{err});
        };
        return null;
    }
    return null;
}

export fn JSValue_fromInt64(globalThis: ?*bun.CLI.BunJS.JSC.JSGlobalObject, number: i64) callconv(.C) JSValueResult {
    if (globalThis) |_globalThis| {
        const v = bun.CLI.BunJS.JSC.JSValue.fromAny(_globalThis, @TypeOf(number), number) catch {
            return JSValueResult{ .is_err = true };
        };
        return JSValueResult{ .value = v };
    }
    return JSValueResult{ .is_err = true };
}

export fn startBunCli(argv_ptr: *[3]usize) void {
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
    bun.initFromCArgv(bun.default_allocator, argv_ptr) catch |err| {
        Output.panic("Failed to initialize argv: {s}\n", .{@errorName(err)});
    };

    Output.Source.Stdio.init();
    defer Output.flush();
    if (Environment.isX64 and Environment.enableSIMD and Environment.isPosix) {
        bun_warn_avx_missing(bun.CLI.UpgradeCommand.Bun__githubBaselineURL.ptr);
    }

    bun.StackCheck.configureThread();

    bun.CLI.Cli.start(bun.default_allocator);
    bun.Global.exit(0);
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
