const std = @import("std");
const ir = @import("ir.zig");
const encode = @import("encode.zig");

pub const Program = union(enum) { vertex_passthrough, fragment_constant: [4]f32 };

pub fn build(allocator: std.mem.Allocator, program: Program) !ir.Module {
    const vertex = program == .vertex_passthrough;
    var shader = ir.Module.init(allocator, if (vertex) .vertex else .fragment);
    errdefer shader.deinit();
    _ = try shader.block();
    if (vertex) try shader.inputs.append(allocator, .{ .name = "POSITION" });
    try shader.outputs.append(allocator, .{
        .name = if (vertex) "SV_Position" else "SV_Target",
        .semantic = if (vertex) .position else .target,
        .interpolation = if (vertex) 4 else 0,
    });
    const zero = try shader.constant(.i32, 0);
    for (0..4) |column| {
        const component = try shader.constant(.i8, @intCast(column));
        const value = if (vertex) try shader.intrinsic(.load_f32, &.{ zero, zero, component, try shader.undef(.i32) }) else try shader.float(program.fragment_constant[column]);
        _ = try shader.intrinsic(.store_f32, &.{ zero, zero, component, value });
    }
    shader.terminate(.ret);
    return shader;
}

pub fn emit(allocator: std.mem.Allocator, program: Program) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var shader = try build(arena.allocator(), program);
    const analysis = try encode.analyze(arena.allocator(), &shader);
    const bytes = try encode.emit(arena.allocator(), &shader, analysis);
    return allocator.dupe(u8, bytes);
}
