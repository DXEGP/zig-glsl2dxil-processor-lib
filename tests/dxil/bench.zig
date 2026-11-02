const std = @import("std");
const processor = @import("processor");

pub fn main(init: std.process.Init) !void {
    const programs = [_]processor.dxil.Program{
        .vertex_passthrough,
        .{ .fragment_constant = .{ 0.25, 0.5, 0.75, 1 } },
    };
    const names = [_][]const u8{ "vertex_passthrough", "fragment_constant" };
    for (programs, names) |program, name| {
        var elapsed: [1001]u64 = undefined;
        var output_size: usize = 0;
        var cold_ns: u64 = 0;
        for (0..elapsed.len + 1) |index| {
            const start = std.Io.Clock.awake.now(init.io);
            const output = try processor.dxil.emit(init.gpa, program, .sm65);
            const end = std.Io.Clock.awake.now(init.io);
            output_size = output.len;
            init.gpa.free(output);
            const duration: u64 = @intCast(start.durationTo(end).toNanoseconds());
            if (index == 0) cold_ns = duration else elapsed[index - 1] = duration;
        }
        std.mem.sort(u64, &elapsed, {}, std.sort.asc(u64));
        var line: [512]u8 = undefined;
        const text = try std.fmt.bufPrint(&line, "program={s} samples={d} bytes={d} first_ns={d} p50_ns={d} p95_ns={d} p99_ns={d} cache=disabled\n", .{
            name, elapsed.len, output_size, cold_ns, elapsed[500], elapsed[950], elapsed[990],
        });
        try std.Io.File.stdout().writeStreamingAll(init.io, text);
    }
}
