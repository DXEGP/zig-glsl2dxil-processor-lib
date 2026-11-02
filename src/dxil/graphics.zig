const std = @import("std");
pub const preprocessing = @import("../glsl/source.zig");
const token = @import("../glsl/token.zig");
const parser = @import("../glsl/parser.zig");
const ast = @import("../glsl/ast.zig");
const diag = @import("../diag.zig");
const container = @import("container.zig");
const sema = @import("sema.zig");
const Lowerer = @import("lower.zig").Lowerer;
const ir = @import("ir.zig");
pub const targets = @import("target.zig");
pub const optimizer = @import("optimize.zig");

pub const Coordinates = enum { opengl, d3d12_native };
pub const Source = struct { source: []const u8, name: []const u8 = "" };
pub const Measurement = struct {
    io: std.Io,
    frontend_ns: u64 = 0,
    semantics_ns: u64 = 0,
    lower_ns: u64 = 0,
    emit_ns: u64 = 0,
    preprocess_ns: u64 = 0,
    parse_ns: u64 = 0,
    optimize_ns: u64 = 0,
    preprocessed_tokens: usize = 0,
};
const Lap = struct {
    measurement: ?*Measurement,
    timestamp: ?std.Io.Timestamp = null,

    fn start(measurement: ?*Measurement) Lap {
        return .{ .measurement = measurement, .timestamp = if (measurement) |value| std.Io.Clock.awake.now(value.io) else null };
    }
    fn finish(self: *Lap, comptime field: []const u8) void {
        if (self.measurement) |measurement| {
            const now = std.Io.Clock.awake.now(measurement.io);
            @field(measurement, field) = @intCast(self.timestamp.?.durationTo(now).toNanoseconds());
            self.timestamp = now;
        }
    }
};
pub const GraphicsRequest = struct {
    vertex: Source,
    fragment: Source,
    target: container.Target = .sm65,
    coordinates: Coordinates = .opengl,
    measurement: ?*Measurement = null,
    binding_mode: targets.BindingMode = .descriptor_tables,
    heap_layout: targets.HeapLayout = .{},
    preprocessing: preprocessing.Config = .{},
    optimization: optimizer.Level = .none,
};
pub const Reflection = struct {
    schema_version: u32 = 1,
    coordinates: Coordinates,
    uniforms: []const sema.Uniform,
    bindings: []const sema.Binding,
    structures: []const sema.Structure,
    vertex_inputs: []const ir.Signature,
    vertex_outputs: []const ir.Signature,
    fragment_inputs: []const ir.Signature,
    fragment_outputs: []const ir.Signature,
    requirements: targets.Requirements,
    binding_mode: targets.BindingMode,
    heap_bindings: []const targets.HeapBinding,
};
pub const GraphicsResult = struct {
    arena: std.heap.ArenaAllocator,
    vertex: []const u8,
    fragment: []const u8,
    reflection: Reflection,
    dependencies: []const preprocessing.Dependency,
    storage: ?*Storage = null,

    pub const Storage = struct { allocator: std.mem.Allocator, arena: std.heap.ArenaAllocator, references: usize = 1 };

    pub fn retain(self: *GraphicsResult, allocator: std.mem.Allocator) error{OutOfMemory}!GraphicsResult {
        if (self.storage == null) {
            const storage = try allocator.create(Storage);
            storage.* = .{ .allocator = allocator, .arena = self.arena };
            self.storage = storage;
        }
        self.storage.?.references += 1;
        return self.*;
    }

    pub fn deinit(self: *GraphicsResult) void {
        if (self.storage) |storage| {
            storage.references -= 1;
            if (storage.references == 0) {
                storage.arena.deinit();
                storage.allocator.destroy(storage);
            }
        } else self.arena.deinit();
        self.* = undefined;
    }
};
pub const Error = error{ InvalidShader, OutOfMemory, UnsupportedTarget };

pub fn compileGraphics(allocator: std.mem.Allocator, request: GraphicsRequest, diagnostics: *diag.Diagnostics) Error!GraphicsResult {
    if (request.target == .sm65 and request.binding_mode == .direct_heap) return error.UnsupportedTarget;
    var lap = Lap.start(request.measurement);
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const scratch = arena.allocator();
    const previous_stage = diagnostics.stage;
    const previous_source = diagnostics.source_name;
    const previous_code = diagnostics.code;
    const previous_map = diagnostics.mappings;
    defer {
        diagnostics.stage = previous_stage;
        diagnostics.source_name = previous_source;
        diagnostics.code = previous_code;
        diagnostics.mappings = previous_map;
    }
    var units: [2]*ast.TranslationUnit = undefined;
    const sources = [_]Source{ request.vertex, request.fragment };
    var names: [2][]const u8 = undefined;
    var maps: [2][]const diag.Mapping = undefined;
    var dependencies: std.ArrayList(preprocessing.Dependency) = .empty;
    if (request.measurement) |measurement| {
        measurement.preprocess_ns = 0;
        measurement.parse_ns = 0;
        measurement.preprocessed_tokens = 0;
    }
    for (sources, &units, &names, 0..) |source, *unit, *name, index| {
        diagnostics.stage = if (index == 0) .vertex else .fragment;
        name.* = try diagnostics.allocator.dupe(u8, if (source.name.len == 0) (if (index == 0) "vertex" else "fragment") else source.name);
        diagnostics.source_name = name.*;
        diagnostics.mappings = &.{};
        if (source.source.len > 1024 * 1024) {
            try diagnostics.err(1, 1, "source exceeds 1 MiB resource limit");
            return error.InvalidShader;
        }
        var frontend_lap = Lap.start(request.measurement);
        const preprocessed = try preprocessing.preprocess(scratch, .{ .source = source.source, .name = name.* }, request.preprocessing, diagnostics);
        if (request.measurement) |measurement| {
            const before = measurement.preprocess_ns;
            frontend_lap.finish("preprocess_ns");
            measurement.preprocess_ns += before;
            measurement.preprocessed_tokens += preprocessed.token_count;
        }
        try dependencies.appendSlice(scratch, preprocessed.dependencies);
        maps[index] = preprocessed.mappings;
        diagnostics.mappings = maps[index];
        const tokens = try token.tokenize(scratch, preprocessed.source, diagnostics);
        if (tokens.len > 262144) {
            try diagnostics.err(1, 1, "source exceeds token resource limit");
            return error.InvalidShader;
        }
        var shader_parser = parser.Parser.init(scratch, tokens, diagnostics);
        unit.* = try shader_parser.parse();
        if (request.measurement) |measurement| {
            const before = measurement.parse_ns;
            frontend_lap.finish("parse_ns");
            measurement.parse_ns += before;
        }
    }
    lap.finish("frontend_ns");
    var program: sema.Program = .{ .allocator = scratch, .diagnostics = diagnostics, .stages = .{ .{ .unit = units[0], .name = names[0], .mappings = maps[0] }, .{ .unit = units[1], .name = names[1], .mappings = maps[1] } }, .opengl = request.coordinates == .opengl };
    try program.analyze();
    const heap_bindings = try scratch.alloc(targets.HeapBinding, if (request.binding_mode == .direct_heap) program.bindings.items.len else 0);
    var resource_index: u64 = request.heap_layout.resource_base;
    var sampler_index: u64 = request.heap_layout.sampler_base;
    for (heap_bindings, program.bindings.items[0..heap_bindings.len], 0..) |*destination, binding, index| {
        const next = if (binding.class == .sampler) &sampler_index else &resource_index;
        if (next.* >= (if (binding.class == .sampler) @as(u64, 2048) else 1000000)) {
            diagnostics.code = .unsupported;
            try diagnostics.err(1, 1, "direct descriptor heap layout exceeds D3D12 heap limits");
            return error.InvalidShader;
        }
        destination.* = .{ .binding_index = @intCast(index), .heap_index = @intCast(next.*) };
        next.* += 1;
    }
    for (program.stages, 0..) |stage, stage_index| for (stage.unit.decls) |declaration| {
        if (declaration.* != .function or declaration.function.body == null) continue;
        var validation_arena = std.heap.ArenaAllocator.init(scratch);
        defer validation_arena.deinit();
        var validator = Lowerer.init(validation_arena.allocator(), &program, stage_index);
        validator.validation_entry = declaration.function.name;
        _ = try validator.lower();
    };
    lap.finish("semantics_ns");
    var vertex_lowerer = Lowerer.init(scratch, &program, 0);
    vertex_lowerer.native_vectors = request.target == .sm69;
    vertex_lowerer.binding_mode = request.binding_mode;
    vertex_lowerer.heap_bindings = heap_bindings;
    var vertex = try vertex_lowerer.lower();
    var fragment_lowerer = Lowerer.init(scratch, &program, 1);
    fragment_lowerer.native_vectors = request.target == .sm69;
    fragment_lowerer.binding_mode = request.binding_mode;
    fragment_lowerer.heap_bindings = heap_bindings;
    var fragment = try fragment_lowerer.lower();
    lap.finish("lower_ns");
    if (request.optimization == .safe) {
        optimizer.optimize(&vertex) catch |err| return backendError(diagnostics, err);
        optimizer.optimize(&fragment) catch |err| return backendError(diagnostics, err);
    }
    lap.finish("optimize_ns");
    if (request.binding_mode == .direct_heap) {
        vertex.resources.clearRetainingCapacity();
        fragment.resources.clearRetainingCapacity();
    }
    var requirements = targets.requirements(&vertex, request.target);
    const fragment_requirements = targets.requirements(&fragment, request.target);
    requirements.feature_flags |= fragment_requirements.feature_flags;
    requirements.root_flags |= fragment_requirements.root_flags;
    requirements.root_signature_version = @max(requirements.root_signature_version, fragment_requirements.root_signature_version);
    requirements.resource_binding_tier = @max(requirements.resource_binding_tier, fragment_requirements.resource_binding_tier);
    requirements.native_vectors = requirements.native_vectors or fragment_requirements.native_vectors;
    const vertex_bytes = container.emitModule(scratch, &vertex, request.target) catch |err| return backendError(diagnostics, err);
    const fragment_bytes = container.emitModule(scratch, &fragment, request.target) catch |err| return backendError(diagnostics, err);
    lap.finish("emit_ns");
    return .{ .arena = arena, .vertex = vertex_bytes, .fragment = fragment_bytes, .dependencies = dependencies.items, .reflection = .{
        .coordinates = request.coordinates,
        .uniforms = program.uniforms.items,
        .bindings = program.bindings.items,
        .structures = program.structures.items,
        .vertex_inputs = vertex.inputs.items,
        .vertex_outputs = vertex.outputs.items,
        .fragment_inputs = fragment.inputs.items,
        .fragment_outputs = fragment.outputs.items,
        .requirements = requirements,
        .binding_mode = request.binding_mode,
        .heap_bindings = heap_bindings,
    } };
}

fn backendError(diagnostics: *diag.Diagnostics, err: anyerror) Error {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    if (err == error.UnsupportedTarget) return error.UnsupportedTarget;
    diagnostics.code = .invalid_ir;
    diagnostics.err(1, 1, "internal IR verification failed") catch return error.OutOfMemory;
    return error.InvalidShader;
}

test "paired GLSL compilation links a varying and owns binary results" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diagnostics = diag.Diagnostics.init(arena.allocator());
    var result = try compileGraphics(std.testing.allocator, .{
        .vertex = .{ .source = "layout(location=0) in vec4 p; out vec2 uv; void main(){ gl_Position=p; uv=p.xy; }" },
        .fragment = .{ .source = "in vec2 uv; out vec4 color; void main(){ color=vec4(uv,0.75,1.0); }" },
        .coordinates = .d3d12_native,
    }, &diagnostics);
    defer result.deinit();
    try container.validate(result.vertex);
    try container.validate(result.fragment);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.items.items.len);
    try std.testing.expectEqual(@as(u32, 0), result.reflection.fragment_inputs[0].index);
}

test "semantic failures retain stage and source diagnostics" {
    const Case = struct { vertex: []const u8 = "void main(){gl_Position=vec4(0,0,0,1);}", fragment: []const u8, message: []const u8 };
    const cases = [_]Case{
        .{ .fragment = "in vec2 missing; out vec4 c; void main(){c=vec4(missing,0,1);}", .message = "no matching vertex" },
        .{ .vertex = "out vec2 uv; void main(){gl_Position=vec4(0,0,0,1);uv=vec2(0);}", .fragment = "in vec3 uv; out vec4 c; void main(){c=vec4(uv,1);}", .message = "incompatible type" },
        .{ .fragment = "uniform sampler2D tex[2]; out vec4 c; void main(){c=vec4(1);}", .message = "sampler arrays" },
        .{ .fragment = "out vec4 c; void main(){c.xx=vec2(1);}", .message = "repeat components" },
        .{ .fragment = "out vec4 c; void f(out float a,out float b){a=1;b=2;} void main(){f(c.x,c.x);}", .message = "overlapping" },
        .{ .fragment = "float f(){return f();} out vec4 c; void main(){c=vec4(f());}", .message = "recursive functions" },
        .{ .fragment = "out vec4 c; void unused(){unknown=1;} void main(){c=vec4(1);}", .message = "not writable" },
        .{ .fragment = "out vec4 c; void main(){c=vec4(1);return;unknown=2;}", .message = "not writable" },
        .{ .fragment = "out vec4 c; float f(float a){float a=1;return a;} void main(){c=vec4(f(0));}", .message = "duplicate local" },
        .{ .fragment = "out vec4 c; void main(){vec2 v;int i=int(gl_FragCoord.x);v[i]=1;c=vec4(v,0,1);}", .message = "dynamic indexing" },
        .{ .fragment = "out vec4 c; void main(){float x[2];c=vec4(x[3]);}", .message = "out of bounds" },
        .{ .fragment = "layout(location=8) out vec4 c; void main(){c=vec4(1);}", .message = "0..7" },
        .{ .fragment = "uniform mat4 huge[4096]; out vec4 c; void main(){c=vec4(1);}", .message = "64 KiB" },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var diagnostics = diag.Diagnostics.init(arena.allocator());
        try std.testing.expectError(error.InvalidShader, compileGraphics(std.testing.allocator, .{
            .vertex = .{ .source = case.vertex, .name = "test.vert" },
            .fragment = .{ .source = case.fragment, .name = "test.frag" },
        }, &diagnostics));
        try std.testing.expect(diagnostics.items.items.len > 0);
        const last = diagnostics.items.items[diagnostics.items.items.len - 1];
        if (std.mem.indexOf(u8, last.message, case.message) == null) std.debug.print("expected {s}, got {s}\n", .{ case.message, last.message });
        try std.testing.expect(std.mem.indexOf(u8, last.message, case.message) != null);
        try std.testing.expectEqual(@import("../options.zig").Stage.fragment, last.stage.?);
        try std.testing.expectEqualStrings("test.frag", last.source_name);
        try std.testing.expect(last.line > 0 and last.column > 0);
    }
}

test "uniform packing and stage linkage remain deterministic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diagnostics = diag.Diagnostics.init(arena.allocator());
    const request: GraphicsRequest = .{
        .vertex = .{ .source = "layout(location=0) in vec4 p; out vec2 z; out vec3 a; uniform vec3 a_vector; uniform float b_scalar; uniform mat3 c_matrix; uniform float d_array[1+2]; void main(){gl_Position=p;z=p.xy;a=a_vector;}" },
        .fragment = .{ .source = "in vec3 a; in vec2 z; out vec4 c; uniform vec3 a_vector; void main(){c=vec4(a+vec3(z,0),1);}" },
        .coordinates = .d3d12_native,
    };
    var first = try compileGraphics(std.testing.allocator, request, &diagnostics);
    defer first.deinit();
    var second = try compileGraphics(std.testing.allocator, request, &diagnostics);
    defer second.deinit();
    try std.testing.expectEqualSlices(u8, first.vertex, second.vertex);
    try std.testing.expectEqualSlices(u8, first.fragment, second.fragment);
    const uniforms = first.reflection.uniforms;
    try std.testing.expectEqual(@as(u32, 0), uniforms[0].offset);
    try std.testing.expectEqual(@as(u32, 3), uniforms[0].stages);
    try std.testing.expectEqual(@as(u32, 12), uniforms[1].offset);
    try std.testing.expectEqual(@as(u32, 16), uniforms[2].offset);
    try std.testing.expectEqual(@as(u32, 48), uniforms[2].size);
    try std.testing.expectEqual(@as(u32, 64), uniforms[3].offset);
    try std.testing.expectEqual(@as(u32, 16), uniforms[3].array_stride);
    for (first.reflection.fragment_inputs) |input| {
        var matched = false;
        for (first.reflection.vertex_outputs) |output| if (output.semantic == .arbitrary and output.index == input.index) {
            try std.testing.expectEqual(output.row, input.row);
            matched = true;
        };
        try std.testing.expect(matched);
    }
}

fn allocationTrial(allocator: std.mem.Allocator, target: container.Target, binding_mode: targets.BindingMode, production: bool) !void {
    var backing = allocator;
    const adapter = struct {
        fn alloc(context: *anyopaque, length: usize, alignment: std.mem.Alignment, address: usize) ?[*]u8 {
            const value: *std.mem.Allocator = @ptrCast(@alignCast(context));
            return value.rawAlloc(length, alignment, address);
        }
        fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, address: usize) void {
            const value: *std.mem.Allocator = @ptrCast(@alignCast(context));
            value.rawFree(memory, alignment, address);
        }
    };
    const deterministic: std.mem.Allocator = .{ .ptr = &backing, .vtable = &.{ .alloc = adapter.alloc, .free = adapter.free, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap } };
    var arena = std.heap.ArenaAllocator.init(deterministic);
    defer arena.deinit();
    var diagnostics = diag.Diagnostics.init(arena.allocator());
    var session = @import("cache.zig").Session.init(deterministic, .{});
    defer session.deinit();
    const request: GraphicsRequest = .{
        .vertex = .{ .source = "layout(location=0) in vec4 p; out vec2 uv; void main(){gl_Position=p;uv=p.xy;}" },
        .fragment = .{ .source = "in vec2 uv; uniform float w[2]; out vec4 c; void main(){float x=0;for(int i=0;i<2;i++){x+=w[i];}c=vec4(uv,x,1);}" },
        .target = target,
        .binding_mode = binding_mode,
        .preprocessing = if (production) .{ .files = &.{.{ .name = "test", .source = "#define F(x) x\n" }} } else .{},
        .optimization = if (production) .safe else .none,
    };
    var result = if (production) try session.compile(request, &diagnostics) else try compileGraphics(deterministic, request, &diagnostics);
    defer result.deinit();
    if (production) {
        var hit = try session.compile(request, &diagnostics);
        defer hit.deinit();
    }
}

test "paired source compilation releases all allocations on failure" {
    for ([_]bool{ false, true }) |production| {
        try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationTrial, .{ container.Target.sm65, targets.BindingMode.descriptor_tables, production });
        try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationTrial, .{ container.Target.sm69, targets.BindingMode.descriptor_tables, production });
        try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationTrial, .{ container.Target.sm69, targets.BindingMode.direct_heap, production });
    }
}

test "included semantic errors retain file and invocation location after temporary memory is freed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diagnostics = diag.Diagnostics.init(arena.allocator());
    try std.testing.expectError(error.InvalidShader, compileGraphics(std.testing.allocator, .{
        .vertex = .{ .source = "void main(){gl_Position=vec4(0,0,0,1);}" },
        .fragment = .{ .name = "main.frag", .source = "#include \"lib/body.glsl\"\n" },
        .preprocessing = .{ .files = &.{.{ .name = "lib/body.glsl", .source = "#define BAD missing_name\nout vec4 c;\nvoid main(){\n c=vec4(BAD);\n}\n" }} },
    }, &diagnostics));
    const failure = diagnostics.items.items[diagnostics.items.items.len - 1];
    try std.testing.expectEqualStrings("lib/body.glsl", failure.source_name);
    try std.testing.expectEqual(@as(u32, 4), failure.line);
    try std.testing.expectEqual(@as(u32, 9), failure.column);
}

test "safe CSE reduces captured arithmetic without changing interfaces" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diagnostics = diag.Diagnostics.init(arena.allocator());
    var request: GraphicsRequest = .{ .vertex = .{ .source = "in vec4 p;void main(){gl_Position=p;}" }, .fragment = .{ .source = "uniform float a;out vec4 c;void main(){float v=a;c=vec4(v*v+v*v+v*v+v*v);}" }, .coordinates = .d3d12_native };
    var baseline = try compileGraphics(std.testing.allocator, request, &diagnostics);
    defer baseline.deinit();
    request.optimization = .safe;
    var optimized = try compileGraphics(std.testing.allocator, request, &diagnostics);
    defer optimized.deinit();
    try std.testing.expect(optimized.fragment.len < baseline.fragment.len);
    try std.testing.expectEqual(baseline.reflection.uniforms[0].offset, optimized.reflection.uniforms[0].offset);
    try std.testing.expectEqual(baseline.reflection.fragment_outputs[0].index, optimized.reflection.fragment_outputs[0].index);
}

test "SM6.9 preserves uniform layouts and signatures and reports heap requirements" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diagnostics = diag.Diagnostics.init(arena.allocator());
    var request: GraphicsRequest = .{
        .vertex = .{ .source = "layout(location=0) in vec4 p; out vec2 uv; void main(){gl_Position=p;uv=p.xy+vec2(0.25);}" },
        .fragment = .{ .source = "in vec2 uv; uniform sampler2D tex; uniform vec3 tint; uniform float alpha; out vec4 c; void main(){c=texture(tex,uv)*vec4(tint,alpha);}" },
    };
    var legacy = try compileGraphics(std.testing.allocator, request, &diagnostics);
    defer legacy.deinit();
    request.target = .sm69;
    for ([_]targets.BindingMode{ .descriptor_tables, .direct_heap }) |mode| {
        request.binding_mode = mode;
        request.heap_layout = .{ .resource_base = 7, .sampler_base = 11 };
        var modern = try compileGraphics(std.testing.allocator, request, &diagnostics);
        defer modern.deinit();
        try std.testing.expectEqualDeep(legacy.reflection.uniforms, modern.reflection.uniforms);
        try std.testing.expectEqualDeep(legacy.reflection.bindings, modern.reflection.bindings);
        try std.testing.expectEqualDeep(legacy.reflection.vertex_inputs, modern.reflection.vertex_inputs);
        try std.testing.expectEqualDeep(legacy.reflection.vertex_outputs, modern.reflection.vertex_outputs);
        try std.testing.expectEqualDeep(legacy.reflection.fragment_inputs, modern.reflection.fragment_inputs);
        try std.testing.expectEqualDeep(legacy.reflection.fragment_outputs, modern.reflection.fragment_outputs);
        const requirements = modern.reflection.requirements;
        try std.testing.expect(requirements.native_vectors);
        try std.testing.expectEqual(@as(u32, 69), requirements.shader_model);
        try std.testing.expectEqual(@as(u32, 3), requirements.psv_version);
        if (mode == .direct_heap) {
            try std.testing.expectEqual(@as(u32, 0xc00), requirements.root_flags);
            try std.testing.expectEqual(@as(u64, 0x6000000), requirements.feature_flags);
            try std.testing.expectEqual(@as(u32, 7), modern.reflection.heap_bindings[0].heap_index);
            try std.testing.expectEqual(@as(u32, 11), modern.reflection.heap_bindings[3].heap_index);
        } else try std.testing.expectEqual(@as(u32, 0), requirements.root_flags);
    }
    request.target = .sm65;
    try std.testing.expectError(error.UnsupportedTarget, compileGraphics(std.testing.allocator, request, &diagnostics));
    request.target = .sm69;
    request.heap_layout.resource_base = 1000000;
    try std.testing.expectError(error.InvalidShader, compileGraphics(std.testing.allocator, request, &diagnostics));
    request.heap_layout = .{ .sampler_base = 2048 };
    try std.testing.expectError(error.InvalidShader, compileGraphics(std.testing.allocator, request, &diagnostics));
}

test "literal and control statement diagnostics preserve source positions" {
    const cases = [_]struct { source: []const u8, line: u32, column: u32 }{
        .{ .source = "out vec4 c;\nvoid main(){\n    break;\n}", .line = 3, .column = 5 },
        .{ .source = "out vec4 c;\nvoid main(){\n    c=vec4(999999999999999999999);\n}", .line = 3, .column = 12 },
        .{ .source = "uniform float a[0];\nvoid main(){}", .line = 1, .column = 17 },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var diagnostics = diag.Diagnostics.init(arena.allocator());
        try std.testing.expectError(error.InvalidShader, compileGraphics(std.testing.allocator, .{
            .vertex = .{ .source = "void main(){gl_Position=vec4(0,0,0,1);}" },
            .fragment = .{ .source = case.source },
        }, &diagnostics));
        const last = diagnostics.items.items[diagnostics.items.items.len - 1];
        try std.testing.expectEqual(case.line, last.line);
        try std.testing.expectEqual(case.column, last.column);
    }
}

test "excessive expression nesting produces a diagnostic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const opening: [300]u8 = @splat('(');
    const closing: [300]u8 = @splat(')');
    const source = try std.fmt.allocPrint(arena.allocator(), "out vec4 c;void main(){{c=vec4({s}1{s});}}", .{ &opening, &closing });
    var diagnostics = diag.Diagnostics.init(arena.allocator());
    try std.testing.expectError(error.InvalidShader, compileGraphics(std.testing.allocator, .{
        .vertex = .{ .source = "void main(){gl_Position=vec4(0,0,0,1);}" },
        .fragment = .{ .source = source },
    }, &diagnostics));
    try std.testing.expect(std.mem.indexOf(u8, diagnostics.items.items[0].message, "nesting") != null);
}
