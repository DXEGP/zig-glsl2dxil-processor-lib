const std = @import("std");
const converter = @import("converter.zig");
const diag = @import("diag.zig");
const options = @import("options.zig");
const dxil = @import("dxil/container.zig");
const graphics_capi = @import("dxil/capi.zig");

export fn glsl2hlsl_dxil_compile_graphics(request: ?*const graphics_capi.Options, result: ?*graphics_capi.Result) c_int {
    return graphics_capi.compile(request, result);
}
export fn glsl2hlsl_dxil_graphics_result_free(result: ?*graphics_capi.Result) void {
    graphics_capi.free(result);
}
export fn glsl2hlsl_dxil_prepare_gl_state(state: ?*const graphics_capi.GlState, prepared: ?*graphics_capi.GlPrepared) c_int {
    return graphics_capi.prepare(state, prepared);
}

const allocator = std.heap.page_allocator;

pub const STATUS_OK: c_int = 0;
pub const STATUS_INVALID_SHADER: c_int = 1;
pub const STATUS_OUT_OF_MEMORY: c_int = 2;
pub const STATUS_INVALID_ARGUMENT: c_int = 3;
pub const STATUS_UNSUPPORTED_TARGET: c_int = 4;

pub const STAGE_AUTO: c_int = 0;
pub const STAGE_VERTEX: c_int = 1;
pub const STAGE_FRAGMENT: c_int = 2;

pub const SEVERITY_ERROR: c_int = 0;
pub const SEVERITY_WARNING: c_int = 1;

pub const Diagnostic = extern struct {
    severity: c_int,
    line: u32,
    column: u32,
    message: ?[*]u8,
    message_length: usize,
};

pub const Result = extern struct {
    status: c_int,
    output: ?[*]u8,
    output_length: usize,
    diagnostics: ?[*]Diagnostic,
    diagnostic_count: usize,
};

fn emptyResult() Result {
    return .{
        .status = STATUS_OK,
        .output = null,
        .output_length = 0,
        .diagnostics = null,
        .diagnostic_count = 0,
    };
}

fn setStatus(result: *Result, status: c_int) c_int {
    result.status = status;
    return status;
}

fn copyBytes(bytes: []const u8) ?[*]u8 {
    const buffer = allocator.alloc(u8, bytes.len + 1) catch return null;
    @memcpy(buffer[0..bytes.len], bytes);
    buffer[bytes.len] = 0;
    return buffer.ptr;
}

fn freeMessage(message: [*]u8, length: usize) void {
    allocator.free(message[0 .. length + 1]);
}

fn copyDiagnostics(items: []const diag.Diagnostic, count: *usize) ?[*]Diagnostic {
    if (items.len == 0) return null;

    const copied = allocator.alloc(Diagnostic, items.len) catch return null;
    var i: usize = 0;
    while (i < items.len) : (i += 1) {
        const message = copyBytes(items[i].message) orelse {
            var j: usize = 0;
            while (j < i) : (j += 1) {
                if (copied[j].message) |pointer| freeMessage(pointer, copied[j].message_length);
            }
            allocator.free(copied);
            return null;
        };
        copied[i] = .{
            .severity = if (items[i].kind == .err) SEVERITY_ERROR else SEVERITY_WARNING,
            .line = items[i].line,
            .column = items[i].column,
            .message = message,
            .message_length = items[i].message.len,
        };
    }

    count.* = items.len;
    return copied.ptr;
}

export fn glsl2hlsl_convert(
    source: ?[*]const u8,
    source_length: usize,
    stage: c_int,
    out_result: ?*Result,
) c_int {
    const result = out_result orelse return STATUS_INVALID_ARGUMENT;
    result.* = emptyResult();

    if (stage < STAGE_AUTO or stage > STAGE_FRAGMENT) return setStatus(result, STATUS_INVALID_ARGUMENT);
    if (source_length != 0 and source == null) return setStatus(result, STATUS_INVALID_ARGUMENT);

    const source_slice: []const u8 = if (source_length == 0) "" else source.?[0..source_length];
    const requested_stage: ?options.Stage = switch (stage) {
        STAGE_VERTEX => .vertex,
        STAGE_FRAGMENT => .fragment,
        else => null,
    };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var diagnostics = diag.Diagnostics.init(arena.allocator());

    const output = converter.convert(
        arena.allocator(),
        source_slice,
        .{ .stage = requested_stage },
        &diagnostics,
    ) catch |err| switch (err) {
        error.InvalidShader => {
            result.status = STATUS_INVALID_SHADER;
            if (diagnostics.items.items.len != 0) {
                const copied = copyDiagnostics(diagnostics.items.items, &result.diagnostic_count);
                if (copied == null) return setStatus(result, STATUS_OUT_OF_MEMORY);
                result.diagnostics = copied;
            }
            return STATUS_INVALID_SHADER;
        },
        error.OutOfMemory => return setStatus(result, STATUS_OUT_OF_MEMORY),
    };

    const output_copy = copyBytes(output) orelse return setStatus(result, STATUS_OUT_OF_MEMORY);
    var diagnostic_count: usize = 0;
    const diagnostic_copy = copyDiagnostics(diagnostics.items.items, &diagnostic_count);
    if (diagnostics.items.items.len != 0 and diagnostic_copy == null) {
        allocator.free(output_copy[0 .. output.len + 1]);
        return setStatus(result, STATUS_OUT_OF_MEMORY);
    }

    result.* = .{
        .status = STATUS_OK,
        .output = output_copy,
        .output_length = output.len,
        .diagnostics = diagnostic_copy,
        .diagnostic_count = diagnostic_count,
    };
    return STATUS_OK;
}

export fn glsl2hlsl_result_free(result: ?*Result) void {
    const value = result orelse return;

    if (value.output) |output| {
        allocator.free(output[0 .. value.output_length + 1]);
    }

    if (value.diagnostics) |items| {
        var i: usize = 0;
        while (i < value.diagnostic_count) : (i += 1) {
            if (items[i].message) |message| freeMessage(message, items[i].message_length);
        }
        allocator.free(items[0..value.diagnostic_count]);
    }

    value.* = emptyResult();
}

export fn glsl2hlsl_version() [*:0]const u8 {
    return "0.1.0";
}

pub const DxilOptions = extern struct {
    program: c_int,
    shader_model: c_int,
    color: [4]f32,
};

pub const DxilResult = extern struct {
    status: c_int = STATUS_OK,
    output: ?[*]u8 = null,
    output_length: usize = 0,
};

export fn glsl2hlsl_dxil_emit(request: ?*const DxilOptions, out_result: ?*DxilResult) c_int {
    const result = out_result orelse return STATUS_INVALID_ARGUMENT;
    result.* = .{};
    const opts = request orelse {
        result.status = STATUS_INVALID_ARGUMENT;
        return result.status;
    };
    const target: dxil.Target = switch (opts.shader_model) {
        65 => .sm65,
        69 => .sm69,
        else => {
            result.status = STATUS_INVALID_ARGUMENT;
            return result.status;
        },
    };
    const program: dxil.Program = switch (opts.program) {
        0 => .vertex_passthrough,
        1 => .{ .fragment_constant = opts.color },
        else => {
            result.status = STATUS_INVALID_ARGUMENT;
            return result.status;
        },
    };
    const output = dxil.emit(allocator, program, target) catch |err| {
        result.status = switch (err) {
            error.OutOfMemory => STATUS_OUT_OF_MEMORY,
            error.UnsupportedTarget => STATUS_UNSUPPORTED_TARGET,
        };
        return result.status;
    };
    result.output = output.ptr;
    result.output_length = output.len;
    return STATUS_OK;
}

export fn glsl2hlsl_dxil_result_free(result: ?*DxilResult) void {
    const value = result orelse return;
    if (value.output) |output| allocator.free(output[0..value.output_length]);
    value.* = .{};
}

test "DXIL C ABI owns binary results and distinguishes unsupported targets" {
    var request: DxilOptions = .{ .program = 1, .shader_model = 65, .color = .{ 0.25, 0.5, 0.75, 1 } };
    var result: DxilResult = undefined;
    try std.testing.expectEqual(STATUS_OK, glsl2hlsl_dxil_emit(&request, &result));
    try dxil.validate(result.output.?[0..result.output_length]);
    glsl2hlsl_dxil_result_free(&result);
    glsl2hlsl_dxil_result_free(&result);
    try std.testing.expectEqual(@as(usize, 0), result.output_length);
    request.shader_model = 69;
    try std.testing.expectEqual(STATUS_UNSUPPORTED_TARGET, glsl2hlsl_dxil_emit(&request, &result));
    try std.testing.expect(result.output == null);
    try std.testing.expectEqual(STATUS_INVALID_ARGUMENT, glsl2hlsl_dxil_emit(null, &result));
    try std.testing.expectEqual(STATUS_INVALID_ARGUMENT, glsl2hlsl_dxil_emit(&request, null));
    request.shader_model = 65;
    request.program = 99;
    try std.testing.expectEqual(STATUS_INVALID_ARGUMENT, glsl2hlsl_dxil_emit(&request, &result));
    request.program = 0;
    request.shader_model = 64;
    try std.testing.expectEqual(STATUS_INVALID_ARGUMENT, glsl2hlsl_dxil_emit(&request, &result));
}

test "C API converts a vertex shader" {
    const source =
        \\#version 330 core
        \\layout(location = 0) in vec3 a_position;
        \\uniform mat4 u_mvp;
        \\void main() {
        \\    gl_Position = u_mvp * vec4(a_position, 1.0);
        \\}
    ;
    var result: Result = undefined;
    const status = glsl2hlsl_convert(source.ptr, source.len, STAGE_VERTEX, &result);
    defer glsl2hlsl_result_free(&result);

    try std.testing.expectEqual(STATUS_OK, status);
    try std.testing.expect(result.output != null);
    const output = result.output.?[0..result.output_length];
    try std.testing.expect(std.mem.indexOf(u8, output, "cbuffer Globals") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "SV_Position") != null);
}

test "C API reports shader errors" {
    const source = "void main() { gl_Position = ; }";
    var result: Result = undefined;
    const status = glsl2hlsl_convert(source.ptr, source.len, STAGE_AUTO, &result);
    defer glsl2hlsl_result_free(&result);

    try std.testing.expectEqual(STATUS_INVALID_SHADER, status);
    try std.testing.expect(result.diagnostic_count != 0);
    try std.testing.expect(result.diagnostics != null);
    const first = result.diagnostics.?[0];
    try std.testing.expect(first.message != null);
    try std.testing.expect(first.message_length != 0);
}

test "C API rejects invalid arguments" {
    var result: Result = undefined;
    try std.testing.expectEqual(STATUS_INVALID_ARGUMENT, glsl2hlsl_convert("", 0, 9, &result));
    try std.testing.expectEqual(STATUS_INVALID_ARGUMENT, glsl2hlsl_convert("", 0, STAGE_AUTO, null));
}

test "C API exposes a version" {
    try std.testing.expectEqualStrings("0.1.0", std.mem.span(glsl2hlsl_version()));
}
