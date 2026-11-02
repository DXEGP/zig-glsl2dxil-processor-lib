const std = @import("std");
const ir = @import("ir.zig");

pub const Target = enum {
    sm65,
    sm69,

    pub fn minor(self: Target) u32 {
        return if (self == .sm65) 5 else 9;
    }
};
pub const BindingMode = enum { descriptor_tables, direct_heap };
pub const HeapLayout = struct { resource_base: u32 = 0, sampler_base: u32 = 0 };
pub const HeapBinding = struct { binding_index: u32, heap_index: u32 };
pub const Requirements = struct {
    shader_model: u32,
    dxil_version: u32,
    validator_version: u32,
    psv_version: u32,
    resource_binding_tier: u32 = 1,
    root_signature_version: u32 = 10,
    root_flags: u32 = 0,
    feature_flags: u64 = 0,
    native_vectors: bool = false,
};

pub fn requirements(shader: *const ir.Module, target: Target) Requirements {
    var result: Requirements = .{ .shader_model = 60 + target.minor(), .dxil_version = 10 + target.minor(), .validator_version = 10 + target.minor(), .psv_version = if (target == .sm65) 1 else 3 };
    for (shader.values.items) |value| {
        result.native_vectors = result.native_vectors or value.typ.lanes() > 1;
        if (value.instruction == .call and value.instruction.call.op == .create_heap) {
            const sampler = shader.values.items[value.instruction.call.args[2]].instruction.constant != 0;
            result.feature_flags |= if (sampler) @as(u64, 0x4000000) else 0x2000000;
            result.root_flags |= if (sampler) @as(u32, 0x800) else 0x400;
            result.root_signature_version = 11;
            result.resource_binding_tier = 3;
        }
    }
    return result;
}

pub fn legalize(allocator: std.mem.Allocator, source: *const ir.Module, target: Target) !ir.Module {
    try source.verify(allocator);
    if (target == .sm65) for (source.values.items) |value| if (value.typ.lanes() > 1) return error.InvalidIr;
    var shader = source.*;
    shader.allocator = allocator;
    shader.values = .empty;
    try shader.values.appendSlice(allocator, source.values.items);
    shader.blocks = .empty;
    for (source.blocks.items) |block| try shader.blocks.append(allocator, .{ .terminator = block.terminator });
    for (source.blocks.items, 0..) |block, block_index| {
        shader.current = @intCast(block_index);
        for (block.values.items) |id| {
            const value = source.values.items[id];
            if (value.instruction == .call) {
                const call = value.instruction.call;
                if (target == .sm65 and (call.op == .create_binding or call.op == .create_heap or call.op == .annotate)) return error.InvalidIr;
                if (target == .sm69 and call.op == .create_handle) {
                    const class = source.values.items[call.args[1]].instruction.constant;
                    const range = source.values.items[call.args[2]].instruction.constant;
                    var ordinal: u32 = 0;
                    for (source.resources.items) |resource| {
                        if (@backingInt(resource.class) != class) continue;
                        defer ordinal += 1;
                        if (ordinal != range) continue;
                        const binding = try shader.add(.res_binding, .{ .aggregate = .{ resource.binding, resource.binding, resource.space, class } });
                        const raw = try shader.intrinsic(.create_binding, &.{ binding, call.args[3], call.args[4] });
                        const props = try shader.add(.res_properties, .{ .aggregate = properties(resource) });
                        const args = try allocator.dupe(ir.ValueId, &.{ try shader.constant(.i32, 216), raw, props });
                        shader.values.items[id].instruction = .{ .call = .{ .op = .annotate, .args = args } };
                        break;
                    }
                }
            }
            try shader.blocks.items[block_index].values.append(allocator, id);
        }
    }
    try shader.verify(allocator);
    return shader;
}

test "target legalization rewrites legacy handles without changing the source" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var source = ir.Module.init(allocator, .fragment);
    _ = try source.block();
    try source.resources.append(allocator, .{ .name = "Globals", .class = .cbuffer, .binding = 3, .space = 2, .size = 16 });
    const handle = try source.intrinsic(.create_handle, &.{ try source.constant(.i8, 2), try source.constant(.i32, 0), try source.constant(.i32, 3), try source.constant(.i1, 0) });
    _ = try source.intrinsic(.cbuffer_f32, &.{ handle, try source.constant(.i32, 0) });
    source.terminate(.ret);
    const legacy = try legalize(allocator, &source, .sm65);
    try std.testing.expectEqual(ir.Op.create_handle, legacy.values.items[handle].instruction.call.op);
    const modern = try legalize(allocator, &source, .sm69);
    try std.testing.expectEqual(ir.Op.annotate, modern.values.items[handle].instruction.call.op);
    const annotation = modern.values.items[handle].instruction.call;
    const binding_call = modern.values.items[annotation.args[1]].instruction.call;
    try std.testing.expectEqual(ir.Op.create_binding, binding_call.op);
    try std.testing.expectEqualDeep([4]u32{ 3, 3, 2, 2 }, modern.values.items[binding_call.args[1]].instruction.aggregate);
    try std.testing.expectEqualDeep([4]u32{ 13, 16, 0, 0 }, modern.values.items[annotation.args[2]].instruction.aggregate);
    try std.testing.expectEqual(ir.Op.create_handle, source.values.items[handle].instruction.call.op);
    try std.testing.expectError(error.InvalidIr, legalize(allocator, &modern, .sm65));
}

pub fn properties(resource: ir.Resource) [4]u32 {
    return switch (resource.class) {
        .cbuffer => .{ 13, resource.size, 0, 0 },
        .srv => .{ 2, 9 | (4 << 8), 0, 0 },
        .sampler => .{ 14, 0, 0, 0 },
        .uav => unreachable,
    };
}
