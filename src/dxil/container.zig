const std = @import("std");
const hash = @import("hash.zig");
const module = @import("module.zig");
pub const ir = @import("ir.zig");
const encode = @import("encode.zig");
pub const graphics = @import("graphics.zig");
pub const compileGraphics = graphics.compileGraphics;
pub const GraphicsRequest = graphics.GraphicsRequest;
pub const GraphicsResult = graphics.GraphicsResult;
pub const compat = @import("compat.zig");

pub const Program = module.Program;
pub const retailHash = hash.retail;
pub const targets = @import("target.zig");
pub const Target = targets.Target;
pub const Error = error{ OutOfMemory, UnsupportedTarget };
pub const ParseError = error{ InvalidContainer, InvalidHash, MissingPart };

const Buffer = struct {
    allocator: std.mem.Allocator,
    data: std.ArrayList(u8) = .empty,

    fn word(self: *Buffer, value: u32) !void {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, value, .little);
        try self.data.appendSlice(self.allocator, &bytes);
    }

    fn append(self: *Buffer, bytes: []const u8) !void {
        try self.data.appendSlice(self.allocator, bytes);
    }
};

fn signature(allocator: std.mem.Allocator, elements: []const ir.Signature, input: bool, target: Target) ![]u8 {
    var buffer: Buffer = .{ .allocator = allocator };
    try buffer.word(@intCast(elements.len));
    try buffer.word(8);
    const order = try allocator.alloc(usize, elements.len);
    const offsets = try allocator.alloc(u32, elements.len);
    var string_offset: u32 = @intCast(8 + elements.len * 32);
    for (elements, 0..) |element, index| {
        order[index] = index;
        offsets[index] = string_offset;
        var shared = false;
        if (target == .sm69 or element.semantic != .arbitrary) for (elements[0..index], 0..) |previous, earlier| {
            if (std.mem.eql(u8, previous.name, element.name)) {
                offsets[index] = offsets[earlier];
                shared = true;
                break;
            }
        };
        if (!shared) string_offset += @intCast(element.name.len + 1);
    }
    std.mem.sort(usize, order, elements, struct {
        fn less(source: []const ir.Signature, left: usize, right: usize) bool {
            const left_row = if (source[left].semantic == .depth) 0xffffffff else source[left].row;
            const right_row = if (source[right].semantic == .depth) 0xffffffff else source[right].row;
            return left_row < right_row or (left_row == right_row and left < right);
        }
    }.less);
    for (order) |index| {
        const element = elements[index];
        try buffer.word(0);
        try buffer.word(offsets[index]);
        try buffer.word(element.index);
        try buffer.word(switch (element.semantic) {
            .arbitrary => 0,
            .position => 1,
            .vertex_id => 6,
            .instance_id => 8,
            .front_face => 9,
            .target => 64,
            .depth => 65,
        });
        try buffer.word(switch (element.scalar) {
            .uint => 1,
            .int => 2,
            .float => 3,
        });
        try buffer.word(if (element.semantic == .depth) 0xffffffff else element.row);
        const mask = (@as(u32, 1) << @intCast(element.columns)) - 1;
        try buffer.word(mask | (@as(u32, if (input) element.usage else ~element.usage & 15) << 8));
        try buffer.word(0);
    }
    var next_string: u32 = @intCast(8 + elements.len * 32);
    for (elements, 0..) |element, index| {
        if (offsets[index] != next_string) continue;
        try buffer.append(element.name);
        try buffer.append(&.{0});
        next_string += @intCast(element.name.len + 1);
    }
    if (target == .sm69) while (buffer.data.items.len % 4 != 0) try buffer.append(&.{0});
    return buffer.data.toOwnedSlice(allocator);
}

fn psvElement(buffer: *Buffer, name_offset: u32, index_offset: u32, element: ir.Signature) !void {
    try buffer.word(name_offset);
    try buffer.word(index_offset);
    try buffer.append(&.{ 1, if (element.semantic == .depth) 0 else @intCast(element.row), element.columns | (if (element.semantic == .depth) @as(u8, 0) else 0x40), @backingInt(element.semantic), switch (element.scalar) {
        .uint => 1,
        .int => 2,
        .float => 3,
    }, element.interpolation, 0, 0 });
}

fn psv(allocator: std.mem.Allocator, shader: *const ir.Module, analysis: encode.Analysis, target: Target) ![]u8 {
    var buffer: Buffer = .{ .allocator = allocator };
    const vertex = shader.stage == .vertex;
    var storage: [52]u8 = @splat(0);
    const runtime = storage[0..if (target == .sm65) @as(usize, 36) else 52];
    for (analysis.outputs) |element| if ((vertex and element.semantic == .position) or (!vertex and element.semantic == .depth)) {
        runtime[0] = 1;
    };
    std.mem.writeInt(u32, runtime[20..24], 0xffffffff, .little);
    runtime[24] = @intFromBool(vertex);
    runtime[28] = @intCast(analysis.inputs.len);
    runtime[29] = @intCast(analysis.outputs.len);
    runtime[31] = @intCast(encode.vectorCount(analysis.inputs));
    runtime[32] = @intCast(encode.vectorCount(analysis.outputs));
    try buffer.word(@intCast(runtime.len));
    const runtime_offset = buffer.data.items.len;
    try buffer.append(runtime);
    try buffer.word(@intCast(shader.resources.items.len));
    if (shader.resources.items.len > 0) {
        try buffer.word(if (target == .sm65) 16 else 24);
        for ([_]@FieldType(ir.Resource, "class"){ .cbuffer, .sampler, .srv, .uav }) |resource_class| for (shader.resources.items) |resource| {
            if (resource.class != resource_class) continue;
            try buffer.word(switch (resource.class) {
                .sampler => 1,
                .cbuffer => 2,
                .srv => 3,
                .uav => 6,
            });
            try buffer.word(resource.space);
            try buffer.word(resource.binding);
            try buffer.word(resource.binding);
            if (target == .sm69) {
                try buffer.word(switch (resource.class) {
                    .cbuffer => 13,
                    .sampler => 14,
                    .srv => 2,
                    .uav => unreachable,
                });
                try buffer.word(0);
            }
        };
    }
    var strings: Buffer = .{ .allocator = allocator };
    try strings.append(&.{0});
    var name_offsets: std.ArrayList(u32) = .empty;
    var indices: std.ArrayList(u32) = .empty;
    for ([_][]const ir.Signature{ analysis.inputs, analysis.outputs }) |elements| for (elements) |element| {
        try name_offsets.append(allocator, if (element.semantic == .arbitrary) @intCast(strings.data.items.len) else 0);
        if (element.semantic == .arbitrary) {
            try strings.append(element.name);
            try strings.append(&.{0});
        }
        try indices.append(allocator, element.index);
    };
    if (target == .sm69) {
        std.mem.writeInt(u32, buffer.data.items[runtime_offset + 48 ..][0..4], @intCast(strings.data.items.len), .little);
        try strings.append("main\x00");
    }
    while (strings.data.items.len % 4 != 0) try strings.append(&.{0});
    try buffer.word(@intCast(strings.data.items.len));
    try buffer.append(strings.data.items);
    try buffer.word(@intCast(indices.items.len));
    for (indices.items) |index| try buffer.word(index);
    if (analysis.inputs.len + analysis.outputs.len != 0) try buffer.word(16);
    var element_index: usize = 0;
    for ([_][]const ir.Signature{ analysis.inputs, analysis.outputs }) |elements| for (elements) |element| {
        try psvElement(&buffer, name_offsets.items[element_index], @intCast(element_index), element);
        element_index += 1;
    };
    const output_words = (analysis.output_count + 31) / 32;
    for (0..@as(usize, runtime[31]) * 4) |input_index| for (0..output_words) |output_word| {
        try buffer.word(if (input_index < analysis.input_count) analysis.dependencies[input_index * output_words + output_word] else 0);
    };
    return buffer.data.toOwnedSlice(allocator);
}

pub fn emit(allocator: std.mem.Allocator, program: Program, target: Target) Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var shader = try module.build(arena.allocator(), program);
    return emitModule(allocator, &shader, target) catch |err| switch (err) {
        error.InvalidIr => unreachable,
        else => |other| return other,
    };
}

pub fn emitModule(allocator: std.mem.Allocator, source: *const ir.Module, target: Target) (Error || error{InvalidIr})![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var legalized = try targets.legalize(scratch, source, target);
    const shader = &legalized;
    const vertex = shader.stage == .vertex;
    const analysis = try encode.analyze(scratch, shader);
    const bitcode = try encode.emit(scratch, shader, analysis, target);
    var dxil: Buffer = .{ .allocator = scratch };
    try dxil.word((@as(u32, @intFromBool(vertex)) << 16) | 0x60 | target.minor());
    try dxil.word(@intCast(6 + bitcode.len / 4));
    try dxil.append("DXIL");
    try dxil.word(0x100 | target.minor());
    try dxil.word(16);
    try dxil.word(@intCast(bitcode.len));
    try dxil.append(bitcode);
    const kinds = [_][]const u8{ "SFI0", "ISG1", "OSG1", "PSV0", "DXIL" };
    var features: [8]u8 = undefined;
    std.mem.writeInt(u64, &features, targets.requirements(shader, target).feature_flags, .little);
    const parts = [_][]const u8{
        &features,
        try signature(scratch, analysis.inputs, true, target),
        try signature(scratch, analysis.outputs, false, target),
        try psv(scratch, shader, analysis, target),
        dxil.data.items,
    };
    var output: Buffer = .{ .allocator = allocator };
    errdefer output.data.deinit(allocator);
    try output.append("DXBC");
    try output.append(&@as([16]u8, @splat(0)));
    try output.word(1);
    try output.word(0);
    try output.word(parts.len);
    for (parts) |_| try output.word(0);
    for (kinds, parts, 0..) |kind, part, index| {
        std.mem.writeInt(u32, output.data.items[32 + index * 4 ..][0..4], @intCast(output.data.items.len), .little);
        try output.append(kind);
        try output.word(@intCast(part.len));
        try output.append(part);
    }
    std.mem.writeInt(u32, output.data.items[24..28], @intCast(output.data.items.len), .little);
    @memcpy(output.data.items[4..20], &hash.retail(output.data.items[20..]));
    return output.data.toOwnedSlice(allocator);
}

fn word(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}

pub fn validate(bytes: []const u8) ParseError!void {
    if (bytes.len < 32 or !std.mem.eql(u8, bytes[0..4], "DXBC")) return error.InvalidContainer;
    if (word(bytes, 20) != 1 or word(bytes, 24) != bytes.len) return error.InvalidContainer;
    const count = word(bytes, 28);
    if (count > (bytes.len - 32) / 4) return error.InvalidContainer;
    var previous_end: usize = 32 + @as(usize, count) * 4;
    for (0..count) |index| {
        const offset = word(bytes, 32 + index * 4);
        if (offset < previous_end or offset > bytes.len or bytes.len - offset < 8) return error.InvalidContainer;
        const length = word(bytes, offset + 4);
        if (length > bytes.len - offset - 8) return error.InvalidContainer;
        previous_end = @as(usize, offset) + 8 + length;
    }
    if (previous_end != bytes.len) return error.InvalidContainer;
    if (!std.mem.eql(u8, bytes[4..20], &hash.retail(bytes[20..]))) return error.InvalidHash;
}

pub fn getPart(bytes: []const u8, kind: *const [4]u8) ParseError![]const u8 {
    try validate(bytes);
    for (0..word(bytes, 28)) |index| {
        const offset = word(bytes, 32 + index * 4);
        if (std.mem.eql(u8, bytes[offset..][0..4], kind)) return bytes[offset + 8 ..][0..word(bytes, offset + 4)];
    }
    return error.MissingPart;
}

test "SM 6.5 programs have deterministic signed containers and real bitcode" {
    const allocator = std.testing.allocator;
    for ([_]Program{ .vertex_passthrough, .{ .fragment_constant = .{ 0.25, 0.5, 0.75, 1 } } }) |program| {
        const first = try emit(allocator, program, .sm65);
        defer allocator.free(first);
        const second = try emit(allocator, program, .sm65);
        defer allocator.free(second);
        try std.testing.expectEqualSlices(u8, first, second);
        const dxil = try getPart(first, "DXIL");
        try std.testing.expectEqual(@as(u32, 0x105), word(dxil, 12));
        try std.testing.expectEqualSlices(u8, "BC\xc0\xde", dxil[24..28]);
        try std.testing.expectEqual(@as(u32, 36), word(try getPart(first, "PSV0"), 0));
    }
}

test "container rejects truncated tables overlapping parts and corrupt digests" {
    const bytes = try emit(std.testing.allocator, .vertex_passthrough, .sm65);
    defer std.testing.allocator.free(bytes);
    for (0..bytes.len) |length| try std.testing.expectError(error.InvalidContainer, validate(bytes[0..length]));
    bytes[4] ^= 1;
    try std.testing.expectError(error.InvalidHash, validate(bytes));
    bytes[4] ^= 1;
    std.mem.writeInt(u32, bytes[32..36], 0, .little);
    try std.testing.expectError(error.InvalidContainer, validate(bytes));
    const modern = try emit(std.testing.allocator, .vertex_passthrough, .sm69);
    defer std.testing.allocator.free(modern);
    try std.testing.expectEqual(@as(u32, 0x109), word(try getPart(modern, "DXIL"), 12));
    try std.testing.expectEqual(@as(u32, 52), word(try getPart(modern, "PSV0"), 0));
}

fn allocationTest(allocator: std.mem.Allocator) !void {
    const bytes = try emit(allocator, .{ .fragment_constant = .{ 1, 0, 0, 1 } }, .sm65);
    defer allocator.free(bytes);
    try validate(bytes);
}

test "DXIL emission releases every allocation on failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationTest, .{});
}
