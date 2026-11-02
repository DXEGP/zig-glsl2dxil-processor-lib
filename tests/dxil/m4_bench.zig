const std = @import("std");
const processor = @import("processor");
const graphics = processor.dxil.graphics;
const Counter = @import("source_bench.zig").Counter;
const Quantiles = struct { p50_ns: u64, p95_ns: u64, p99_ns: u64 };
const Report = struct {
    name: []const u8,
    target: []const u8,
    binding_mode: []const u8,
    optimization: []const u8,
    samples: u32 = 101,
    first_ns: u64,
    uncached: Quantiles,
    cache_hit: Quantiles,
    preprocess: Quantiles,
    parse: Quantiles,
    semantics: Quantiles,
    ssa: Quantiles,
    optimize: Quantiles,
    encode: Quantiles,
    tokens: usize,
    peak_requested_bytes: usize,
    output_bytes: usize,
    cache_retained_bytes: usize,
};
const Package = struct { name: []const u8, sha256: []const u8, files: []const processor.source.File };
const Inputs = struct { packages: []const Package };
const Case = struct { name: []const u8, vertex: graphics.Source, fragment: graphics.Source, files: []const processor.source.File = &.{} };

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const json = try std.Io.Dir.cwd().readFileAlloc(init.io, "zig-out/m4/inputs.json", allocator, .limited(64 * 1024 * 1024));
    const inputs = try std.json.parseFromSlice(Inputs, allocator, json, .{ .allocate = .alloc_always });
    var cases: std.ArrayList(Case) = .empty;
    for ([_][]const u8{ "position_color", "position" }) |name| {
        const vertex_name = try std.fmt.allocPrint(allocator, "assets/minecraft/shaders/core/{s}.vsh", .{name});
        const fragment_name = try std.fmt.allocPrint(allocator, "assets/minecraft/shaders/core/{s}.fsh", .{name});
        var vertex: ?graphics.Source = null;
        var fragment: ?graphics.Source = null;
        for (inputs.value.packages[0].files) |file| {
            if (std.mem.eql(u8, vertex_name, file.name)) vertex = .{ .source = file.source, .name = file.name };
            if (std.mem.eql(u8, fragment_name, file.name)) fragment = .{ .source = file.source, .name = file.name };
        }
        try cases.append(allocator, .{ .name = try std.fmt.allocPrint(allocator, "minecraft-{s}", .{name}), .vertex = vertex.?, .fragment = fragment.?, .files = inputs.value.packages[0].files });
    }
    for ([_]usize{ 8, 32, 128 }) |repetitions| {
        var source: std.ArrayList(u8) = .empty;
        try source.appendSlice(allocator, "uniform float a;out vec4 c;void main(){float v=a;float x=0;");
        for (0..repetitions) |_| try source.appendSlice(allocator, "x+=(v*v+v*v);");
        try source.appendSlice(allocator, "c=vec4(x);}");
        try cases.append(allocator, .{ .name = try std.fmt.allocPrint(allocator, "repeated-{d}", .{repetitions}), .vertex = .{ .source = "in vec4 p;void main(){gl_Position=p;}" }, .fragment = .{ .source = source.items } });
    }
    var reports: std.ArrayList(Report) = .empty;
    for (cases.items) |case| for (0..3) |configuration| for ([_]graphics.optimizer.Level{ .none, .safe }) |optimization| {
        const request: graphics.GraphicsRequest = .{ .vertex = case.vertex, .fragment = case.fragment, .preprocessing = .{ .files = case.files }, .target = if (configuration == 0) .sm65 else .sm69, .binding_mode = if (configuration == 2) .direct_heap else .descriptor_tables, .heap_layout = .{ .resource_base = 3, .sampler_base = 5 }, .optimization = optimization };
        var times: [101]u64 = undefined;
        var stages: [6][101]u64 = undefined;
        var first: u64 = 0;
        var peak: usize = 0;
        var size: usize = 0;
        var tokens: usize = 0;
        for (0..102) |iteration| {
            var counter: Counter = .{ .backing = init.gpa };
            var arena = std.heap.ArenaAllocator.init(counter.allocator());
            var diagnostics = processor.diag.Diagnostics.init(arena.allocator());
            var measurement: graphics.Measurement = .{ .io = init.io };
            var measured = request;
            measured.measurement = &measurement;
            const start = std.Io.Clock.awake.now(init.io);
            var result = try processor.compileGraphics(counter.allocator(), measured, &diagnostics);
            const elapsed: u64 = @intCast(start.durationTo(std.Io.Clock.awake.now(init.io)).toNanoseconds());
            if (iteration == 0) first = elapsed else {
                times[iteration - 1] = elapsed;
                const readings = [_]u64{ measurement.preprocess_ns, measurement.parse_ns, measurement.semantics_ns, measurement.lower_ns, measurement.optimize_ns, measurement.emit_ns };
                for (&stages, readings) |*stage, reading| stage[iteration - 1] = reading;
            }
            size = result.vertex.len + result.fragment.len;
            tokens = measurement.preprocessed_tokens;
            peak = @max(peak, counter.peak);
            result.deinit();
            arena.deinit();
            if (counter.live != 0) return error.LeakedCompilerMemory;
        }
        var session = processor.CompileSession.init(init.gpa, .{});
        defer session.deinit();
        var diagnostics = processor.diag.Diagnostics.init(allocator);
        var warmup = try session.compile(request, &diagnostics);
        warmup.deinit();
        var hits: [101]u64 = undefined;
        for (&hits) |*hit| {
            const start = std.Io.Clock.awake.now(init.io);
            var result = try session.compile(request, &diagnostics);
            hit.* = @intCast(start.durationTo(std.Io.Clock.awake.now(init.io)).toNanoseconds());
            result.deinit();
        }
        if (session.stats.hits != hits.len) return error.CacheMiss;
        try reports.append(allocator, .{ .name = case.name, .target = @tagName(request.target), .binding_mode = @tagName(request.binding_mode), .optimization = @tagName(optimization), .first_ns = first, .uncached = quantiles(&times), .cache_hit = quantiles(&hits), .preprocess = quantiles(&stages[0]), .parse = quantiles(&stages[1]), .semantics = quantiles(&stages[2]), .ssa = quantiles(&stages[3]), .optimize = quantiles(&stages[4]), .encode = quantiles(&stages[5]), .tokens = tokens, .peak_requested_bytes = peak, .output_bytes = size, .cache_retained_bytes = session.stats.bytes });
        const progress = try std.fmt.allocPrint(allocator, "{s} {s} {s} {s} p50_ns={d}\n", .{ case.name, @tagName(request.target), @tagName(request.binding_mode), @tagName(optimization), reports.items[reports.items.len - 1].uncached.p50_ns });
        try std.Io.File.stdout().writeStreamingAll(init.io, progress);
    };
    const report = try std.json.Stringify.valueAlloc(allocator, .{ .schema_version = 1, .file_io = "excluded", .pso = "excluded; recorded independently by source_render.cpp", .memory = "peak requested live allocator bytes; not process RSS", .cache = "explicit session; hash all VFS bytes; hits measured separately", .reports = reports.items }, .{ .whitespace = .indent_2 });
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = "zig-out/m4/benchmark.json", .data = report });
}

fn quantiles(values: *[101]u64) Quantiles {
    std.mem.sort(u64, values, {}, std.sort.asc(u64));
    return .{ .p50_ns = values[50], .p95_ns = values[95], .p99_ns = values[99] };
}
