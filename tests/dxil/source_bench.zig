const std = @import("std");
const processor = @import("processor");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

pub const Counter = struct {
    backing: Allocator,
    live: usize = 0,
    peak: usize = 0,

    pub fn allocator(self: *Counter) Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = Allocator.noResize, .remap = Allocator.noRemap, .free = free } };
    }
    fn alloc(context: *anyopaque, length: usize, alignment: Alignment, address: usize) ?[*]u8 {
        const self: *Counter = @ptrCast(@alignCast(context));
        const result = self.backing.rawAlloc(length, alignment, address) orelse return null;
        self.live += length;
        self.peak = @max(self.peak, self.live);
        return result;
    }
    fn free(context: *anyopaque, memory: []u8, alignment: Alignment, address: usize) void {
        const self: *Counter = @ptrCast(@alignCast(context));
        self.live -= memory.len;
        self.backing.rawFree(memory, alignment, address);
    }
};

pub fn main(init: std.process.Init) !void {
    const cases = [_][2][]const u8{
        .{ "examples/triangle.vert", "examples/triangle.frag" },
        .{ "examples/showcase.vert", "examples/showcase.frag" },
    };
    for (cases) |paths| {
        const vertex = try std.Io.Dir.cwd().readFileAlloc(init.io, paths[0], init.arena.allocator(), .limited(1024 * 1024));
        const fragment = try std.Io.Dir.cwd().readFileAlloc(init.io, paths[1], init.arena.allocator(), .limited(1024 * 1024));
        var elapsed: [101]u64 = undefined;
        var stages: [4][101]u64 = undefined;
        var first_ns: u64 = 0;
        var peak: usize = 0;
        var output_size: usize = 0;
        for (0..102) |iteration| {
            var counter: Counter = .{ .backing = init.gpa };
            var arena = std.heap.ArenaAllocator.init(counter.allocator());
            var diagnostics = processor.diag.Diagnostics.init(arena.allocator());
            var measurement: processor.dxil.graphics.Measurement = .{ .io = init.io };
            const start = std.Io.Clock.awake.now(init.io);
            var result = try processor.compileGraphics(counter.allocator(), .{
                .vertex = .{ .source = vertex, .name = paths[0] },
                .fragment = .{ .source = fragment, .name = paths[1] },
                .measurement = &measurement,
            }, &diagnostics);
            const end = std.Io.Clock.awake.now(init.io);
            const duration: u64 = @intCast(start.durationTo(end).toNanoseconds());
            if (iteration == 0) first_ns = duration else {
                elapsed[iteration - 1] = duration;
                stages[0][iteration - 1] = measurement.frontend_ns;
                stages[1][iteration - 1] = measurement.semantics_ns;
                stages[2][iteration - 1] = measurement.lower_ns;
                stages[3][iteration - 1] = measurement.emit_ns;
            }
            output_size = result.vertex.len + result.fragment.len;
            peak = @max(peak, counter.peak);
            result.deinit();
            arena.deinit();
            if (counter.live != 0) return error.LeakedCompilerMemory;
        }
        std.mem.sort(u64, &elapsed, {}, std.sort.asc(u64));
        for (&stages) |*stage| std.mem.sort(u64, stage, {}, std.sort.asc(u64));
        var buffer: [1024]u8 = undefined;
        const line = try std.fmt.bufPrint(&buffer, "pair={s}+{s} samples=101 first_ns={d} p50_ns={d} p95_ns={d} p99_ns={d} frontend_p50_ns={d} semantics_p50_ns={d} lower_p50_ns={d} emit_p50_ns={d} peak_requested_bytes={d} output_bytes={d} cache=disabled file_io=excluded pso=excluded\n", .{ paths[0], paths[1], first_ns, elapsed[50], elapsed[95], elapsed[99], stages[0][50], stages[1][50], stages[2][50], stages[3][50], peak, output_size });
        try std.Io.File.stdout().writeStreamingAll(init.io, line);
    }
}
