const std = @import("std");
const processor = @import("processor");

const vertex = "layout(location=0) in vec4 p; void main(){gl_Position=p;}";
const color = "out vec4 color; void main(){color=vec4(0.25,0.5,0.75,1.0);}";
const uv_vertex = "layout(location=0) in vec4 p; layout(location=1) in vec2 uv; out vec2 v_uv; void main(){gl_Position=p; v_uv=uv;}";
const Case = struct { name: []const u8, vertex_path: ?[]const u8 = null, fragment_path: ?[]const u8 = null, vertex_source: []const u8 = vertex, fragment_source: []const u8 = color, native: bool = false };

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 2) return error.ExpectedOutputDirectory;
    try std.Io.Dir.cwd().createDirPath(init.io, args[1]);
    const cases = [_]Case{
        .{ .name = "source-basic", .native = true },
        .{ .name = "vectors", .fragment_path = "tests/dxil/vectors.frag", .native = true },
        .{ .name = "triangle", .vertex_path = "examples/triangle.vert", .fragment_path = "examples/triangle.frag" },
        .{ .name = "showcase", .vertex_path = "examples/showcase.vert", .fragment_path = "examples/showcase.frag" },
        .{ .name = "features-vertex", .vertex_path = "tests/shaders/features.vert", .fragment_source = "in vec2 v_uv; out vec4 c; void main(){c=vec4(v_uv,0.75,1.0);}" },
        .{ .name = "features-fragment", .vertex_source = "layout(location=0) in vec4 p; layout(location=1) in vec2 uv; layout(location=2) in vec3 color; out vec2 v_uv; out vec3 v_color; void main(){gl_Position=p;v_uv=uv;v_color=color;}", .fragment_path = "tests/shaders/features.frag" },
        .{ .name = "builtins-vertex", .vertex_path = "tests/shaders/builtins.vert" },
        .{ .name = "builtins-fragment", .fragment_path = "tests/shaders/builtins.frag" },
        .{ .name = "structs", .vertex_source = uv_vertex, .fragment_path = "tests/shaders/structs.frag" },
        .{ .name = "legacy", .vertex_source = uv_vertex, .fragment_path = "tests/shaders/legacy.frag" },
    };
    const Configuration = struct { target: processor.dxil.Target, heap: bool = false, directory: []const u8 };
    for ([_]Configuration{ .{ .target = .sm65, .directory = args[1] }, .{ .target = .sm69, .directory = try std.fmt.allocPrint(allocator, "{s}/../m3", .{args[1]}) }, .{ .target = .sm69, .heap = true, .directory = try std.fmt.allocPrint(allocator, "{s}/../m3-heap", .{args[1]}) } }) |configuration| for (cases) |case| {
        const directory = configuration.directory;
        try std.Io.Dir.cwd().createDirPath(init.io, directory);
        const vertex_source = if (case.vertex_path) |path| try std.Io.Dir.cwd().readFileAlloc(init.io, path, allocator, .limited(1024 * 1024)) else case.vertex_source;
        const fragment_source = if (case.fragment_path) |path| try std.Io.Dir.cwd().readFileAlloc(init.io, path, allocator, .limited(1024 * 1024)) else case.fragment_source;
        var diagnostics = processor.diag.Diagnostics.init(allocator);
        var result = processor.compileGraphics(init.gpa, .{
            .vertex = .{ .source = vertex_source, .name = case.vertex_path orelse case.name },
            .fragment = .{ .source = fragment_source, .name = case.fragment_path orelse case.name },
            .coordinates = if (case.native) .d3d12_native else .opengl,
            .target = configuration.target,
            .binding_mode = if (configuration.heap) .direct_heap else .descriptor_tables,
            .heap_layout = .{ .resource_base = 3, .sampler_base = 5 },
        }, &diagnostics) catch |err| {
            for (diagnostics.items.items) |diagnostic| std.debug.print("{s}:{d}:{d}: {s}\n", .{ diagnostic.source_name, diagnostic.line, diagnostic.column, diagnostic.message });
            return err;
        };
        defer result.deinit();
        const vertex_path = try std.fmt.allocPrint(allocator, "{s}/{s}.vert.dxil", .{ directory, case.name });
        const fragment_path = try std.fmt.allocPrint(allocator, "{s}/{s}.frag.dxil", .{ directory, case.name });
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = vertex_path, .data = result.vertex });
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = fragment_path, .data = result.fragment });
        const reflection = try std.json.Stringify.valueAlloc(allocator, .{ .schema_version = 1, .coordinates = result.reflection.coordinates, .uniforms = result.reflection.uniforms, .bindings = result.reflection.bindings, .vertex_inputs = result.reflection.vertex_inputs, .vertex_outputs = result.reflection.vertex_outputs, .fragment_inputs = result.reflection.fragment_inputs, .fragment_outputs = result.reflection.fragment_outputs }, .{ .whitespace = .indent_2 });
        const reflection_path = try std.fmt.allocPrint(allocator, "{s}/{s}.reflection.json", .{ directory, case.name });
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = reflection_path, .data = reflection });
        std.debug.print("compiled pair: {s}\n", .{case.name});
    };
}
