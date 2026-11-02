const std = @import("std");
const ir = @import("ir.zig");

pub const Level = enum { none, safe };
const Key = struct { tag: u8, typ: ir.Type, operation: u32 = 0, left: u32 = 0, right: u32 = 0, extra: u32 = 0 };

pub fn optimize(module: *ir.Module) error{ OutOfMemory, InvalidShader }!void {
    module.verify(module.allocator) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidShader;
    const allocator = module.allocator;
    const aliases = try allocator.alloc(u32, module.values.items.len);
    defer allocator.free(aliases);
    for (aliases, 0..) |*alias, index| alias.* = @intCast(index);
    var expressions: std.AutoHashMapUnmanaged(Key, u32) = .empty;
    defer expressions.deinit(allocator);
    for (module.blocks.items) |*block| {
        expressions.clearRetainingCapacity();
        var kept: usize = 0;
        for (block.values.items) |id| {
            const value = &module.values.items[id];
            try remap(allocator, &value.instruction, aliases);
            if (key(value.*)) |expression| {
                if (expressions.get(expression)) |previous| {
                    aliases[id] = previous;
                    value.instruction = .undef;
                    continue;
                }
                try expressions.put(allocator, expression, id);
            }
            block.values.items[kept] = id;
            kept += 1;
        }
        block.values.items.len = kept;
    }
    for (module.values.items) |*value| try remap(allocator, &value.instruction, aliases);
    for (module.blocks.items) |*block| if (block.terminator == .conditional) {
        block.terminator.conditional.condition = resolve(aliases, block.terminator.conditional.condition);
    };
    const live = try allocator.alloc(bool, module.values.items.len);
    defer allocator.free(live);
    @memset(live, false);
    var work: std.ArrayList(u32) = .empty;
    defer work.deinit(allocator);
    for (module.values.items, 0..) |value, id| if (value.instruction == .call) try work.append(allocator, @intCast(id));
    for (module.blocks.items) |block| if (block.terminator == .conditional) try work.append(allocator, block.terminator.conditional.condition);
    while (work.pop()) |id| {
        if (live[id]) continue;
        live[id] = true;
        try operands(allocator, &work, module.values.items[id].instruction);
    }
    for (module.blocks.items) |*block| {
        var kept: usize = 0;
        for (block.values.items) |id| {
            if (!live[id]) {
                const instruction = module.values.items[id].instruction;
                if (instruction == .phi) allocator.free(instruction.phi);
                module.values.items[id].instruction = .undef;
                continue;
            }
            block.values.items[kept] = id;
            kept += 1;
        }
        block.values.items.len = kept;
    }
    module.verify(allocator) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidShader;
}

fn resolve(aliases: []const u32, value: u32) u32 {
    var current = value;
    while (aliases[current] != current) current = aliases[current];
    return current;
}

fn key(value: ir.Value) ?Key {
    return switch (value.instruction) {
        .binary => |operation| .{ .tag = 1, .typ = value.typ, .operation = @backingInt(operation.op), .left = operation.left, .right = operation.right },
        .compare => |operation| .{ .tag = 2, .typ = value.typ, .operation = @backingInt(operation.predicate), .left = operation.left, .right = operation.right },
        .cast => |operation| .{ .tag = 3, .typ = value.typ, .operation = @backingInt(operation.op), .left = operation.value },
        .insert => |operation| .{ .tag = 4, .typ = value.typ, .left = operation.vector, .right = operation.value, .extra = operation.index },
        .element => |operation| .{ .tag = 5, .typ = value.typ, .left = operation.vector, .right = operation.index },
        .select => |operation| .{ .tag = 6, .typ = value.typ, .left = operation.condition, .right = operation.yes, .extra = operation.no },
        .extract => |operation| .{ .tag = 7, .typ = value.typ, .left = operation.value, .extra = operation.index },
        else => null,
    };
}

fn remap(allocator: std.mem.Allocator, instruction: *ir.Instruction, aliases: []const u32) !void {
    switch (instruction.*) {
        .binary => |*operation| {
            operation.left = resolve(aliases, operation.left);
            operation.right = resolve(aliases, operation.right);
        },
        .compare => |*operation| {
            operation.left = resolve(aliases, operation.left);
            operation.right = resolve(aliases, operation.right);
        },
        .cast => |*operation| operation.value = resolve(aliases, operation.value),
        .select => |*operation| {
            operation.condition = resolve(aliases, operation.condition);
            operation.yes = resolve(aliases, operation.yes);
            operation.no = resolve(aliases, operation.no);
        },
        .insert => |*operation| {
            operation.vector = resolve(aliases, operation.vector);
            operation.value = resolve(aliases, operation.value);
            operation.index = resolve(aliases, operation.index);
        },
        .element => |*operation| {
            operation.vector = resolve(aliases, operation.vector);
            operation.index = resolve(aliases, operation.index);
        },
        .extract => |*operation| operation.value = resolve(aliases, operation.value),
        .phi => |*incoming| {
            const replacement = try allocator.dupe(ir.Incoming, incoming.*);
            for (replacement) |*edge| edge.value = resolve(aliases, edge.value);
            allocator.free(incoming.*);
            incoming.* = replacement;
        },
        .call => |*operation| {
            const replacement = try allocator.dupe(u32, operation.args);
            for (replacement) |*argument| argument.* = resolve(aliases, argument.*);
            allocator.free(operation.args);
            operation.args = replacement;
        },
        else => {},
    }
}

fn operands(allocator: std.mem.Allocator, work: *std.ArrayList(u32), instruction: ir.Instruction) !void {
    switch (instruction) {
        .binary => |operation| try work.appendSlice(allocator, &.{ operation.left, operation.right }),
        .compare => |operation| try work.appendSlice(allocator, &.{ operation.left, operation.right }),
        .cast => |operation| try work.append(allocator, operation.value),
        .select => |operation| try work.appendSlice(allocator, &.{ operation.condition, operation.yes, operation.no }),
        .insert => |operation| try work.appendSlice(allocator, &.{ operation.vector, operation.value, operation.index }),
        .element => |operation| try work.appendSlice(allocator, &.{ operation.vector, operation.index }),
        .extract => |operation| try work.append(allocator, operation.value),
        .phi => |incoming| for (incoming) |edge| {
            try work.append(allocator, edge.value);
        },
        .call => |operation| try work.appendSlice(allocator, operation.args),
        else => {},
    }
}
