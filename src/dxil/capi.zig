const std = @import("std");
const graphics = @import("graphics.zig");
const diag = @import("../diag.zig");
const sema = @import("sema.zig");
const ir = @import("ir.zig");
const compat = @import("compat.zig");
const allocator = std.heap.page_allocator;

pub const Type = extern struct { scalar: u32, rows: u32, columns: u32, array_length: u32, structure_index: u32 };
pub const Uniform = extern struct { name: [*:0]const u8, name_length: usize, typ: Type, offset: u32, size: u32, array_stride: u32, matrix_stride: u32, stages: u32 };
pub const Binding = extern struct { name: [*:0]const u8, name_length: usize, resource_class: u32, binding: u32, space: u32, size: u32, stages: u32 };
pub const Field = extern struct { name: [*:0]const u8, name_length: usize, typ: Type, offset: u32 };
pub const Structure = extern struct { name: [*:0]const u8, name_length: usize, fields: [*]const Field, field_count: usize, size: u32 };
pub const Signature = extern struct { name: [*:0]const u8, name_length: usize, semantic_index: u32, row: u32, columns: u32, scalar: u32, semantic: u32, interpolation: u32, stage: u32, is_input: u32 };
pub const Diagnostic = extern struct { severity: u32, stage: u32, code: u32, line: u32, column: u32, source_name: [*:0]const u8, source_name_length: usize, message: [*:0]const u8, message_length: usize };
pub const Options = extern struct {
    vertex_source: ?[*]const u8,
    vertex_source_length: usize,
    vertex_name: ?[*]const u8,
    vertex_name_length: usize,
    fragment_source: ?[*]const u8,
    fragment_source_length: usize,
    fragment_name: ?[*]const u8,
    fragment_name_length: usize,
    shader_model: c_int,
    coordinates: c_int,
};
pub const OptionsEx = extern struct { struct_size: usize, base: Options, binding_mode: u32, resource_heap_base: u32, sampler_heap_base: u32 };
pub const HeapBinding = extern struct { binding_index: u32, heap_index: u32 };
pub const ExecutionInfo = extern struct {
    shader_model: u32 = 0,
    dxil_version: u32 = 0,
    validator_version: u32 = 0,
    psv_version: u32 = 0,
    resource_binding_tier: u32 = 0,
    root_signature_version: u32 = 0,
    root_flags: u32 = 0,
    native_vectors: u32 = 0,
    feature_flags: u64 = 0,
    binding_mode: u32 = 0,
    heap_bindings: ?[*]const HeapBinding = null,
    heap_binding_count: usize = 0,
};
pub const Result = extern struct {
    status: c_int = 0,
    owner: ?*anyopaque = null,
    vertex: ?[*]const u8 = null,
    vertex_length: usize = 0,
    fragment: ?[*]const u8 = null,
    fragment_length: usize = 0,
    reflection_version: u32 = 0,
    coordinates: u32 = 0,
    uniforms: ?[*]const Uniform = null,
    uniform_count: usize = 0,
    bindings: ?[*]const Binding = null,
    binding_count: usize = 0,
    structures: ?[*]const Structure = null,
    structure_count: usize = 0,
    signatures: ?[*]const Signature = null,
    signature_count: usize = 0,
    diagnostics: ?[*]const Diagnostic = null,
    diagnostic_count: usize = 0,
};
const Owner = struct { arena: std.heap.ArenaAllocator, result: ?graphics.GraphicsResult = null, execution: ExecutionInfo = .{} };
pub const Text = extern struct { data: ?[*]const u8, length: usize };
pub const File = extern struct { name: Text, source: Text };
pub const Define = extern struct { name: Text, value: Text };
pub const Limits = extern struct {
    file_bytes: usize,
    input_bytes: usize,
    output_bytes: usize,
    tokens: usize,
    expansions: usize,
    include_depth: u32,
    macro_depth: u32,
    condition_depth: u32,
    expression_depth: u32,
};
pub const OptionsV2 = extern struct {
    struct_size: usize,
    base: OptionsEx,
    files: ?[*]const File,
    file_count: usize,
    defines: ?[*]const Define,
    define_count: usize,
    include_dirs: ?[*]const Text,
    include_dir_count: usize,
    limits: ?*const Limits,
    optimization: u32,
};
pub const Session = @import("cache.zig").Session;
pub const CacheStats = extern struct { hits: usize, misses: usize, evictions: usize, bytes: usize };

pub fn sessionCreate(entries: usize, bytes: usize) ?*Session {
    const session = allocator.create(Session) catch return null;
    session.* = Session.init(allocator, .{ .entries = entries, .bytes = bytes });
    return session;
}
pub fn sessionFree(session: ?*Session) void {
    if (session) |value| {
        value.deinit();
        allocator.destroy(value);
    }
}
pub fn sessionStats(session: ?*const Session, output: ?*CacheStats) c_int {
    const destination = output orelse return 3;
    destination.* = std.mem.zeroes(CacheStats);
    const value = session orelse return 3;
    destination.* = .{ .hits = value.stats.hits, .misses = value.stats.misses, .evictions = value.stats.evictions, .bytes = value.stats.bytes };
    return 0;
}
fn validText(value: Text) bool {
    return value.data != null or value.length == 0;
}
pub fn compileV2(session: ?*Session, request: ?*const OptionsV2, out_result: ?*Result) c_int {
    const result = out_result orelse return 3;
    result.* = .{};
    const options = request orelse {
        result.status = 3;
        return 3;
    };
    if (options.struct_size != @sizeOf(OptionsV2) or options.base.struct_size != @sizeOf(OptionsEx) or options.base.binding_mode > 1 or options.optimization > 1 or
        (options.files == null and options.file_count != 0) or (options.defines == null and options.define_count != 0) or (options.include_dirs == null and options.include_dir_count != 0))
    {
        result.status = 3;
        return 3;
    }
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const files = scratch.alloc(graphics.preprocessing.File, options.file_count) catch return outOfMemory(result);
    for (files, 0..) |*destination, index| {
        const source = options.files.?[index];
        if (!validText(source.name) or !validText(source.source)) {
            result.status = 3;
            return 3;
        }
        destination.* = .{ .name = slice(source.name.data, source.name.length), .source = slice(source.source.data, source.source.length) };
    }
    const defines = scratch.alloc(graphics.preprocessing.Define, options.define_count) catch return outOfMemory(result);
    for (defines, 0..) |*destination, index| {
        const source = options.defines.?[index];
        if (!validText(source.name) or !validText(source.value)) {
            result.status = 3;
            return 3;
        }
        destination.* = .{ .name = slice(source.name.data, source.name.length), .value = slice(source.value.data, source.value.length) };
    }
    const directories = scratch.alloc([]const u8, options.include_dir_count) catch return outOfMemory(result);
    for (directories, 0..) |*destination, index| {
        const source = options.include_dirs.?[index];
        if (!validText(source)) {
            result.status = 3;
            return 3;
        }
        destination.* = slice(source.data, source.length);
    }
    var limits: graphics.preprocessing.Limits = .{};
    if (options.limits) |value| limits = .{ .file_bytes = value.file_bytes, .input_bytes = value.input_bytes, .output_bytes = value.output_bytes, .tokens = value.tokens, .expansions = value.expansions, .include_depth = value.include_depth, .macro_depth = value.macro_depth, .condition_depth = value.condition_depth, .expression_depth = value.expression_depth };
    return compileImpl(&options.base.base, result, if (options.base.binding_mode == 0) .descriptor_tables else .direct_heap, .{ .resource_base = options.base.resource_heap_base, .sampler_base = options.base.sampler_heap_base }, .{ .files = files, .defines = defines, .include_dirs = directories, .limits = limits }, if (options.optimization == 0) .none else .safe, session);
}

pub fn free(result: ?*Result) void {
    const value = result orelse return;
    if (value.owner) |pointer| {
        const owner: *Owner = @ptrCast(@alignCast(pointer));
        if (owner.result) |*owned| owned.deinit();
        owner.arena.deinit();
        allocator.destroy(owner);
    }
    value.* = .{};
}

fn outOfMemory(result: *Result) c_int {
    free(result);
    result.status = 2;
    return 2;
}
fn slice(pointer: ?[*]const u8, length: usize) []const u8 {
    return if (length == 0) "" else pointer.?[0..length];
}
fn convertType(typ: sema.Type) Type {
    return .{ .scalar = @backingInt(typ.scalar), .rows = typ.rows, .columns = typ.cols, .array_length = typ.array_len, .structure_index = typ.structure };
}

pub fn compile(request: ?*const Options, out_result: ?*Result) c_int {
    return compileImpl(request, out_result, .descriptor_tables, .{}, .{}, .none, null);
}

pub fn compileEx(request: ?*const OptionsEx, out_result: ?*Result) c_int {
    const result = out_result orelse return 3;
    result.* = .{};
    const options = request orelse {
        result.status = 3;
        return 3;
    };
    if (options.struct_size != @sizeOf(OptionsEx) or options.binding_mode > 1) {
        result.status = 3;
        return 3;
    }
    return compileImpl(&options.base, result, if (options.binding_mode == 0) .descriptor_tables else .direct_heap, .{ .resource_base = options.resource_heap_base, .sampler_base = options.sampler_heap_base }, .{}, .none, null);
}

pub fn executionInfo(result: ?*const Result, output: ?*ExecutionInfo) c_int {
    const info = output orelse return 3;
    info.* = .{};
    const value = result orelse return 3;
    if (value.status != 0 or value.owner == null) return 3;
    const owner: *const Owner = @ptrCast(@alignCast(value.owner.?));
    info.* = owner.execution;
    return 0;
}

fn compileImpl(request: ?*const Options, out_result: ?*Result, binding_mode: graphics.targets.BindingMode, heap_layout: graphics.targets.HeapLayout, preprocessing: graphics.preprocessing.Config, optimization: graphics.optimizer.Level, session: ?*Session) c_int {
    const result = out_result orelse return 3;
    result.* = .{};
    const options = request orelse {
        result.status = 3;
        return 3;
    };
    if ((options.vertex_source == null and options.vertex_source_length != 0) or (options.fragment_source == null and options.fragment_source_length != 0) or (options.vertex_name == null and options.vertex_name_length != 0) or (options.fragment_name == null and options.fragment_name_length != 0) or options.coordinates < 0 or options.coordinates > 1 or (options.shader_model != 65 and options.shader_model != 69)) {
        result.status = 3;
        return 3;
    }
    const owner = allocator.create(Owner) catch return outOfMemory(result);
    owner.* = .{ .arena = std.heap.ArenaAllocator.init(allocator) };
    result.owner = owner;
    const scratch = owner.arena.allocator();
    var diagnostics = diag.Diagnostics.init(scratch);
    const compile_request: graphics.GraphicsRequest = .{
        .vertex = .{ .source = slice(options.vertex_source, options.vertex_source_length), .name = slice(options.vertex_name, options.vertex_name_length) },
        .fragment = .{ .source = slice(options.fragment_source, options.fragment_source_length), .name = slice(options.fragment_name, options.fragment_name_length) },
        .coordinates = if (options.coordinates == 0) .opengl else .d3d12_native,
        .target = if (options.shader_model == 65) .sm65 else .sm69,
        .binding_mode = binding_mode,
        .heap_layout = heap_layout,
        .preprocessing = preprocessing,
        .optimization = optimization,
    };
    owner.result = (if (session) |value| value.compile(compile_request, &diagnostics) else graphics.compileGraphics(allocator, compile_request, &diagnostics)) catch |err| switch (err) {
        error.OutOfMemory => return outOfMemory(result),
        error.UnsupportedTarget => {
            free(result);
            result.status = 4;
            return 4;
        },
        error.InvalidShader => null,
    };
    copyDiagnostics(scratch, diagnostics.items.items, result) catch return outOfMemory(result);
    if (owner.result) |*compiled| {
        copyReflection(scratch, compiled.reflection, result) catch return outOfMemory(result);
        const requirements = compiled.reflection.requirements;
        const heap_bindings = scratch.alloc(HeapBinding, compiled.reflection.heap_bindings.len) catch return outOfMemory(result);
        for (heap_bindings, compiled.reflection.heap_bindings) |*destination, source| destination.* = .{ .binding_index = source.binding_index, .heap_index = source.heap_index };
        owner.execution = .{ .shader_model = requirements.shader_model, .dxil_version = requirements.dxil_version, .validator_version = requirements.validator_version, .psv_version = requirements.psv_version, .resource_binding_tier = requirements.resource_binding_tier, .root_signature_version = requirements.root_signature_version, .root_flags = requirements.root_flags, .feature_flags = requirements.feature_flags, .native_vectors = @intFromBool(requirements.native_vectors), .binding_mode = @backingInt(compiled.reflection.binding_mode), .heap_bindings = if (heap_bindings.len == 0) null else heap_bindings.ptr, .heap_binding_count = heap_bindings.len };
        result.vertex = compiled.vertex.ptr;
        result.vertex_length = compiled.vertex.len;
        result.fragment = compiled.fragment.ptr;
        result.fragment_length = compiled.fragment.len;
        result.status = 0;
    } else result.status = 1;
    return result.status;
}

fn copyDiagnostics(scratch: std.mem.Allocator, source: []const diag.Diagnostic, result: *Result) !void {
    if (source.len == 0) return;
    const copied = try scratch.alloc(Diagnostic, source.len);
    for (copied, source) |*destination, item| destination.* = .{
        .severity = @backingInt(item.kind),
        .stage = if (item.stage) |stage| (if (stage == .vertex) @as(u32, 1) else 2) else 0,
        .code = @backingInt(item.code),
        .line = item.line,
        .column = item.column,
        .source_name = try scratch.dupeSentinel(u8, item.source_name, 0),
        .source_name_length = item.source_name.len,
        .message = try scratch.dupeSentinel(u8, item.message, 0),
        .message_length = item.message.len,
    };
    result.diagnostics = copied.ptr;
    result.diagnostic_count = copied.len;
}

fn copyReflection(scratch: std.mem.Allocator, reflection: graphics.Reflection, result: *Result) !void {
    const uniforms = try scratch.alloc(Uniform, reflection.uniforms.len);
    for (uniforms, reflection.uniforms) |*destination, source| destination.* = .{ .name = try scratch.dupeSentinel(u8, source.name, 0), .name_length = source.name.len, .typ = convertType(source.typ), .offset = source.offset, .size = source.size, .array_stride = source.array_stride, .matrix_stride = source.matrix_stride, .stages = source.stages };
    result.uniforms = if (uniforms.len == 0) null else uniforms.ptr;
    result.uniform_count = uniforms.len;
    const bindings = try scratch.alloc(Binding, reflection.bindings.len);
    for (bindings, reflection.bindings) |*destination, source| destination.* = .{ .name = try scratch.dupeSentinel(u8, source.name, 0), .name_length = source.name.len, .resource_class = @backingInt(source.class), .binding = source.binding, .space = source.space, .size = source.size, .stages = source.stages };
    result.bindings = if (bindings.len == 0) null else bindings.ptr;
    result.binding_count = bindings.len;
    const structures = try scratch.alloc(Structure, reflection.structures.len);
    for (structures, reflection.structures) |*destination, source| {
        const fields = try scratch.alloc(Field, source.fields.len);
        for (fields, source.fields) |*field, item| field.* = .{ .name = try scratch.dupeSentinel(u8, item.name, 0), .name_length = item.name.len, .typ = convertType(item.typ), .offset = item.offset };
        destination.* = .{ .name = try scratch.dupeSentinel(u8, source.decl.name, 0), .name_length = source.decl.name.len, .fields = fields.ptr, .field_count = fields.len, .size = source.size };
    }
    result.structures = if (structures.len == 0) null else structures.ptr;
    result.structure_count = structures.len;
    var signatures: std.ArrayList(Signature) = .empty;
    const groups = [_][]const ir.Signature{ reflection.vertex_inputs, reflection.vertex_outputs, reflection.fragment_inputs, reflection.fragment_outputs };
    for (groups, 0..) |group, index| for (group) |source| {
        try signatures.append(scratch, .{ .name = try scratch.dupeSentinel(u8, source.name, 0), .name_length = source.name.len, .semantic_index = source.index, .row = source.row, .columns = source.columns, .scalar = switch (source.scalar) {
            .float => 4,
            .int => 2,
            .uint => 3,
        }, .semantic = @backingInt(source.semantic), .interpolation = source.interpolation, .stage = if (index < 2) 1 else 2, .is_input = if (index % 2 == 0) 1 else 0 });
    };
    result.signatures = if (signatures.items.len == 0) null else signatures.items.ptr;
    result.signature_count = signatures.items.len;
    result.reflection_version = reflection.schema_version;
    result.coordinates = @backingInt(reflection.coordinates);
}

pub const GlState = extern struct { clip_origin: u32, clip_depth: u32, winding: u32, viewport_x: f32, viewport_y: f32, viewport_width: f32, viewport_height: f32, target_height: f32, depth_near: f32, depth_far: f32, base_instance: u32 };
pub const GlPrepared = extern struct { constants: [8]u32, viewport: [6]f32, front_counter_clockwise: u32, start_instance_location: u32 };

pub fn prepare(state: ?*const GlState, prepared: ?*GlPrepared) c_int {
    const output = prepared orelse return 3;
    output.* = std.mem.zeroes(GlPrepared);
    const input = state orelse return 3;
    if (input.clip_origin > 1 or input.clip_depth > 1 or input.winding > 1) return 3;
    const value = compat.prepare(.{ .clip_origin = @fromBackingInt(@intCast(input.clip_origin)), .clip_depth = @fromBackingInt(@intCast(input.clip_depth)), .winding = @fromBackingInt(@intCast(input.winding)), .viewport_x = input.viewport_x, .viewport_y = input.viewport_y, .viewport_width = input.viewport_width, .viewport_height = input.viewport_height, .target_height = input.target_height, .depth_near = input.depth_near, .depth_far = input.depth_far, .base_instance = input.base_instance }) catch return 3;
    output.* = .{ .constants = value.constants, .viewport = value.viewport, .front_counter_clockwise = @intFromBool(value.front_counter_clockwise), .start_instance_location = value.start_instance_location };
    return 0;
}
