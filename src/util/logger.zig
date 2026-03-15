const std = @import("std");

var log_timer: ?std.time.Timer = null;

pub fn customLogFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    _ = level;
    if (log_timer == null) log_timer = std.time.Timer.start() catch null;

    const elapsed_ns = if (log_timer) |*t| t.read() else 0;
    const elapsed_ms = elapsed_ns / std.time.ns_per_ms;
    const ms = elapsed_ms % 1000;
    const sec = (elapsed_ms / 1000) % 60;
    const min = (elapsed_ms / 60000) % 60;
    const hr = (elapsed_ms / 3600000);

    const scope_str = if (scope == .default) "zig" else @tagName(scope);

    // --- ZIG 0.15 "WRITERGATE" IO PATTERN ---

    // 1. Define an explicit buffer for the writer
    var buf: [1024]u8 = undefined;

    // 2. Pass it directly to the new stderr interface
    var stderr_writer = std.fs.File.stderr().writer(&buf);
    const writer = &stderr_writer.interface;

    writer.print("{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3} [{s}] ", .{ hr, min, sec, ms, scope_str }) catch return;
    writer.print(format, args) catch return;
    writer.writeByte('\n') catch return;

    // 3. Since it is buffered by default, we MUST flush it before the function returns
    writer.flush() catch return;
}

pub const options: std.Options = .{
    .logFn = customLogFn,
};
