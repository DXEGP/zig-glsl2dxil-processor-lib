const std = @import("std");

pub const Stage = enum { vertex, fragment };
pub const Type = enum { void_, i1, i8, i32, f32, i8_ptr, handle, cb_f32, cb_i32, res_f32 };
pub const ValueId = u32;
pub const BlockId = u32;
pub const BinaryOp = enum { add, sub, mul, udiv, sdiv, fdiv, urem, srem, shl, lshr, ashr, and_, or_, xor_ };
pub const Predicate = enum { eq, ne, ugt, uge, ult, ule, sgt, sge, slt, sle, oeq, one, ogt, oge, olt, ole, une };
pub const CastOp = enum { trunc, zext, sext, fptoui, fptosi, uitofp, sitofp, bitcast };

pub const Op = enum {
    load_f32,
    load_i32,
    store_f32,
    store_i32,
    unary,
    binary,
    tertiary,
    create_handle,
    cbuffer_f32,
    cbuffer_i32,
    sample,
    sample_level,
    texture_load,
    discard,

    pub const Definition = struct { name: []const u8, ret: Type, params: []const Type, opcode: u32, memory: enum { none, read, write } = .none };

    pub fn definition(self: Op) Definition {
        return switch (self) {
            .load_f32 => .{ .name = "dx.op.loadInput.f32", .ret = .f32, .params = &.{ .i32, .i32, .i32, .i8, .i32 }, .opcode = 4 },
            .load_i32 => .{ .name = "dx.op.loadInput.i32", .ret = .i32, .params = &.{ .i32, .i32, .i32, .i8, .i32 }, .opcode = 4 },
            .store_f32 => .{ .name = "dx.op.storeOutput.f32", .ret = .void_, .params = &.{ .i32, .i32, .i32, .i8, .f32 }, .opcode = 5, .memory = .write },
            .store_i32 => .{ .name = "dx.op.storeOutput.i32", .ret = .void_, .params = &.{ .i32, .i32, .i32, .i8, .i32 }, .opcode = 5, .memory = .write },
            .unary => .{ .name = "dx.op.unary.f32", .ret = .f32, .params = &.{ .i32, .f32 }, .opcode = 0 },
            .binary => .{ .name = "dx.op.binary.f32", .ret = .f32, .params = &.{ .i32, .f32, .f32 }, .opcode = 0 },
            .tertiary => .{ .name = "dx.op.tertiary.f32", .ret = .f32, .params = &.{ .i32, .f32, .f32, .f32 }, .opcode = 0 },
            .create_handle => .{ .name = "dx.op.createHandle", .ret = .handle, .params = &.{ .i32, .i8, .i32, .i32, .i1 }, .opcode = 57, .memory = .read },
            .cbuffer_f32 => .{ .name = "dx.op.cbufferLoadLegacy.f32", .ret = .cb_f32, .params = &.{ .i32, .handle, .i32 }, .opcode = 59, .memory = .read },
            .cbuffer_i32 => .{ .name = "dx.op.cbufferLoadLegacy.i32", .ret = .cb_i32, .params = &.{ .i32, .handle, .i32 }, .opcode = 59, .memory = .read },
            .sample => .{ .name = "dx.op.sample.f32", .ret = .res_f32, .params = &.{ .i32, .handle, .handle, .f32, .f32, .f32, .f32, .i32, .i32, .i32, .f32 }, .opcode = 60, .memory = .read },
            .sample_level => .{ .name = "dx.op.sampleLevel.f32", .ret = .res_f32, .params = &.{ .i32, .handle, .handle, .f32, .f32, .f32, .f32, .i32, .i32, .i32, .f32 }, .opcode = 62, .memory = .read },
            .texture_load => .{ .name = "dx.op.textureLoad.f32", .ret = .res_f32, .params = &.{ .i32, .handle, .i32, .i32, .i32, .i32, .i32, .i32, .i32 }, .opcode = 66, .memory = .read },
            .discard => .{ .name = "dx.op.discard", .ret = .void_, .params = &.{ .i32, .i1 }, .opcode = 82, .memory = .write },
        };
    }
};

pub const Incoming = struct { value: ValueId, block: BlockId };
pub const Instruction = union(enum) {
    constant: u32,
    undef,
    binary: struct { op: BinaryOp, left: ValueId, right: ValueId },
    compare: struct { predicate: Predicate, left: ValueId, right: ValueId },
    cast: struct { op: CastOp, value: ValueId },
    select: struct { condition: ValueId, yes: ValueId, no: ValueId },
    phi: []const Incoming,
    call: struct { op: Op, args: []const ValueId },
    extract: struct { value: ValueId, index: u32 },
};
pub const Value = struct { typ: Type, instruction: Instruction };
pub const Terminator = union(enum) { none, ret, branch: BlockId, conditional: struct { condition: ValueId, yes: BlockId, no: BlockId } };
pub const Block = struct { values: std.ArrayList(ValueId) = .empty, terminator: Terminator = .none };
pub const Semantic = enum(u8) { arbitrary = 0, vertex_id = 1, instance_id = 2, position = 3, front_face = 13, target = 16, depth = 17 };
pub const Signature = struct {
    name: []const u8,
    index: u32 = 0,
    row: u32 = 0,
    columns: u8 = 4,
    scalar: enum { float, int, uint } = .float,
    semantic: Semantic = .arbitrary,
    interpolation: u8 = 0,
    usage: u8 = 0,
};
pub const Resource = struct { name: []const u8, class: enum(u8) { srv = 0, uav = 1, cbuffer = 2, sampler = 3 }, binding: u32, space: u32 = 0, size: u32 = 0 };

pub const Module = struct {
    allocator: std.mem.Allocator,
    stage: Stage,
    values: std.ArrayList(Value) = .empty,
    blocks: std.ArrayList(Block) = .empty,
    inputs: std.ArrayList(Signature) = .empty,
    outputs: std.ArrayList(Signature) = .empty,
    resources: std.ArrayList(Resource) = .empty,
    current: BlockId = 0,

    pub fn init(allocator: std.mem.Allocator, stage: Stage) Module {
        return .{ .allocator = allocator, .stage = stage };
    }

    pub fn deinit(self: *Module) void {
        for (self.values.items) |value| switch (value.instruction) {
            .phi => |incoming| self.allocator.free(incoming),
            .call => |operation| self.allocator.free(operation.args),
            else => {},
        };
        for (self.blocks.items) |*block_value| block_value.values.deinit(self.allocator);
        self.blocks.deinit(self.allocator);
        self.values.deinit(self.allocator);
        self.inputs.deinit(self.allocator);
        self.outputs.deinit(self.allocator);
        self.resources.deinit(self.allocator);
    }

    pub fn block(self: *Module) !BlockId {
        const result: BlockId = @intCast(self.blocks.items.len);
        try self.blocks.append(self.allocator, .{});
        return result;
    }

    pub fn constant(self: *Module, typ: Type, bits: u32) !ValueId {
        for (self.values.items, 0..) |value, index| {
            if (value.typ == typ and value.instruction == .constant and value.instruction.constant == bits) return @intCast(index);
        }
        return self.add(typ, .{ .constant = bits });
    }

    pub fn float(self: *Module, number: f32) !ValueId {
        return self.constant(.f32, @bitCast(number));
    }

    pub fn undef(self: *Module, typ: Type) !ValueId {
        for (self.values.items, 0..) |value, index| if (value.typ == typ and value.instruction == .undef) {
            return @intCast(index);
        };
        return self.add(typ, .undef);
    }

    pub fn add(self: *Module, typ: Type, instruction: Instruction) !ValueId {
        const result: ValueId = @intCast(self.values.items.len);
        try self.values.append(self.allocator, .{ .typ = typ, .instruction = instruction });
        errdefer _ = self.values.pop();
        if (instruction != .constant and instruction != .undef) {
            try self.blocks.items[self.current].values.append(self.allocator, result);
        }
        return result;
    }

    pub fn binary(self: *Module, op: BinaryOp, left: ValueId, right: ValueId) !ValueId {
        return self.add(self.values.items[left].typ, .{ .binary = .{ .op = op, .left = left, .right = right } });
    }

    pub fn compare(self: *Module, predicate: Predicate, left: ValueId, right: ValueId) !ValueId {
        return self.add(.i1, .{ .compare = .{ .predicate = predicate, .left = left, .right = right } });
    }

    pub fn call(self: *Module, op: Op, args: []const ValueId) !ValueId {
        const copy = try self.allocator.dupe(ValueId, args);
        errdefer self.allocator.free(copy);
        return self.add(op.definition().ret, .{ .call = .{ .op = op, .args = copy } });
    }

    pub fn intrinsic(self: *Module, op: Op, args: []const ValueId) !ValueId {
        var operands: [16]ValueId = undefined;
        operands[0] = try self.constant(.i32, op.definition().opcode);
        @memcpy(operands[1..][0..args.len], args);
        return self.call(op, operands[0 .. args.len + 1]);
    }

    pub fn phi(self: *Module, typ: Type, incoming: []const Incoming) !ValueId {
        const copy = try self.allocator.dupe(Incoming, incoming);
        errdefer self.allocator.free(copy);
        return self.add(typ, .{ .phi = copy });
    }

    pub fn terminate(self: *Module, terminator: Terminator) void {
        std.debug.assert(self.blocks.items[self.current].terminator == .none);
        self.blocks.items[self.current].terminator = terminator;
    }

    pub fn verify(self: *const Module, allocator: std.mem.Allocator) !void {
        const invalid = error.InvalidIr;
        const count = self.blocks.items.len;
        if (count == 0 or count > 4096 or self.values.items.len > 1000000) return invalid;
        for ([_][]const Signature{ self.inputs.items, self.outputs.items }, 0..) |elements, direction| {
            var rows: [32]bool = @splat(false);
            for (elements, 0..) |element, index| {
                if (element.columns == 0 or element.columns > 4 or element.interpolation > 4 or element.name.len == 0) return invalid;
                if (element.semantic == .depth) {
                    if (self.stage != .fragment or direction != 1 or element.columns != 1 or element.scalar != .float or element.row != 0xffffffff) return invalid;
                } else {
                    if (element.row >= 32 or rows[element.row]) return invalid;
                    rows[element.row] = true;
                }
                for (elements[0..index]) |previous| if (previous.semantic == element.semantic and previous.index == element.index and std.mem.eql(u8, previous.name, element.name)) return invalid;
                switch (element.semantic) {
                    .vertex_id, .instance_id => if (self.stage != .vertex or direction != 0 or element.columns != 1 or element.scalar != .uint) return invalid,
                    .front_face => if (self.stage != .fragment or direction != 0 or element.columns != 1 or element.scalar != .uint) return invalid,
                    .position => if ((self.stage == .vertex) != (direction == 1) or element.columns != 4 or element.scalar != .float) return invalid,
                    .target => if (self.stage != .fragment or direction != 1 or element.index >= 8 or element.row != element.index) return invalid,
                    else => {},
                }
            }
        }
        for (self.resources.items, 0..) |resource, index| {
            if (resource.class == .uav or resource.name.len == 0) return invalid;
            if (resource.class == .cbuffer and (resource.size == 0 or resource.size > 65536 or resource.size % 16 != 0)) return invalid;
            for (self.resources.items[0..index]) |previous| if (previous.class == resource.class and previous.binding == resource.binding and previous.space == resource.space) return invalid;
        }
        const owners = try allocator.alloc(?BlockId, self.values.items.len);
        defer allocator.free(owners);
        @memset(owners, null);
        const positions = try allocator.alloc(usize, self.values.items.len);
        defer allocator.free(positions);
        const predecessors = try allocator.alloc(bool, count * count);
        defer allocator.free(predecessors);
        @memset(predecessors, false);
        for (self.blocks.items, 0..) |block_value, block_index| {
            var non_phi = false;
            for (block_value.values.items, 0..) |value_id, position| {
                if (value_id >= self.values.items.len or owners[value_id] != null) return invalid;
                const value = self.values.items[value_id];
                if (value.instruction == .constant or value.instruction == .undef) return invalid;
                if (value.instruction == .phi) {
                    if (non_phi) return invalid;
                } else non_phi = true;
                owners[value_id] = @intCast(block_index);
                positions[value_id] = position;
            }
            switch (block_value.terminator) {
                .none => return invalid,
                .ret => {},
                .branch => |target| {
                    if (target >= count) return invalid;
                    predecessors[target * count + block_index] = true;
                },
                .conditional => |branch| {
                    if (branch.yes >= count or branch.no >= count or branch.condition >= self.values.items.len or self.values.items[branch.condition].typ != .i1) return invalid;
                    predecessors[branch.yes * count + block_index] = true;
                    predecessors[branch.no * count + block_index] = true;
                },
            }
        }
        const dominators = try allocator.alloc(bool, count * count);
        defer allocator.free(dominators);
        @memset(dominators, true);
        @memset(dominators[0..count], false);
        dominators[0] = true;
        var changed = true;
        while (changed) {
            changed = false;
            for (1..count) |block_index| for (0..count) |candidate| {
                var dominates = candidate == block_index;
                if (!dominates) {
                    dominates = true;
                    var has_predecessor = false;
                    for (0..count) |predecessor| if (predecessors[block_index * count + predecessor]) {
                        has_predecessor = true;
                        dominates = dominates and dominators[predecessor * count + candidate];
                    };
                    dominates = dominates and has_predecessor;
                }
                const position = block_index * count + candidate;
                if (dominators[position] != dominates) {
                    dominators[position] = dominates;
                    changed = true;
                }
            };
        }
        for (self.values.items, 0..) |value, value_index| {
            if (value.instruction == .constant or value.instruction == .undef) {
                if (value.typ != .i1 and value.typ != .i8 and value.typ != .i32 and value.typ != .f32) return invalid;
                if (value.instruction == .constant and ((value.typ == .i1 and value.instruction.constant > 1) or (value.typ == .i8 and value.instruction.constant > 255))) return invalid;
                continue;
            }
            const owner = owners[value_index] orelse return invalid;
            var operands: [16]ValueId = undefined;
            var length: usize = 0;
            switch (value.instruction) {
                .constant, .undef => unreachable,
                .binary => |operation| {
                    operands[0..2].* = .{ operation.left, operation.right };
                    length = 2;
                    if (!self.hasType(operation.left, value.typ) or !self.hasType(operation.right, value.typ)) return invalid;
                    if (value.typ != .f32 and value.typ != .i32 and value.typ != .i1) return invalid;
                    if (value.typ == .f32 and operation.op != .add and operation.op != .sub and operation.op != .mul and operation.op != .fdiv) return invalid;
                    if (value.typ != .f32 and operation.op == .fdiv) return invalid;
                    if (value.typ == .i1 and operation.op != .and_ and operation.op != .or_ and operation.op != .xor_) return invalid;
                },
                .compare => |operation| {
                    operands[0..2].* = .{ operation.left, operation.right };
                    length = 2;
                    if (value.typ != .i1 or operation.left >= self.values.items.len or !self.hasType(operation.right, self.values.items[operation.left].typ)) return invalid;
                    const floating = self.values.items[operation.left].typ == .f32;
                    if (!floating and self.values.items[operation.left].typ != .i1 and self.values.items[operation.left].typ != .i8 and self.values.items[operation.left].typ != .i32) return invalid;
                    if (floating != (@backingInt(operation.predicate) >= @backingInt(Predicate.oeq))) return invalid;
                },
                .cast => |operation| {
                    operands[0] = operation.value;
                    length = 1;
                    if (operation.value >= self.values.items.len) return invalid;
                    const source = self.values.items[operation.value].typ;
                    const source_bits = integerBits(source);
                    const target_bits = integerBits(value.typ);
                    const valid = switch (operation.op) {
                        .trunc => source_bits > target_bits and target_bits != 0,
                        .zext, .sext => source_bits != 0 and source_bits < target_bits,
                        .fptoui, .fptosi => source == .f32 and target_bits != 0,
                        .uitofp, .sitofp => source_bits != 0 and value.typ == .f32,
                        .bitcast => (source == .f32 and value.typ == .i32) or (source == .i32 and value.typ == .f32),
                    };
                    if (!valid) return invalid;
                },
                .select => |operation| {
                    operands[0..3].* = .{ operation.condition, operation.yes, operation.no };
                    length = 3;
                    if (!self.hasType(operation.condition, .i1) or !self.hasType(operation.yes, value.typ) or !self.hasType(operation.no, value.typ)) return invalid;
                },
                .call => |operation| {
                    const definition = operation.op.definition();
                    if (definition.ret != value.typ or definition.params.len != operation.args.len or operation.args.len > operands.len) return invalid;
                    for (operation.args, definition.params) |argument, typ| if (!self.hasType(argument, typ)) return invalid;
                    const opcode = self.immediate(operation.args[0]) orelse return invalid;
                    if (definition.opcode != 0 and opcode != definition.opcode) return invalid;
                    switch (operation.op) {
                        .unary => if (std.mem.indexOfScalar(u32, &.{ 6, 12, 13, 22, 24, 25, 27, 28, 29 }, opcode) == null) return invalid,
                        .binary => if (opcode != 35 and opcode != 36) return invalid,
                        .tertiary => return invalid,
                        .load_f32, .load_i32, .store_f32, .store_i32 => {
                            const input = operation.op == .load_f32 or operation.op == .load_i32;
                            const signatures = if (input) self.inputs.items else self.outputs.items;
                            const element = self.immediate(operation.args[1]) orelse return invalid;
                            const row = self.immediate(operation.args[2]) orelse return invalid;
                            const column = self.immediate(operation.args[3]) orelse return invalid;
                            if (element >= signatures.len or row != 0 or column >= signatures[element].columns) return invalid;
                            if ((signatures[element].scalar == .float) != (operation.op == .load_f32 or operation.op == .store_f32)) return invalid;
                        },
                        .create_handle => {
                            const class = self.immediate(operation.args[1]) orelse return invalid;
                            const range = self.immediate(operation.args[2]) orelse return invalid;
                            const binding = self.immediate(operation.args[3]) orelse return invalid;
                            var current: u32 = 0;
                            var found = false;
                            for (self.resources.items) |resource| if (@backingInt(resource.class) == class) {
                                if (current == range and binding == resource.binding) found = true;
                                current += 1;
                            };
                            if (!found) return invalid;
                        },
                        .sample => if (self.stage != .fragment) return invalid,
                        .discard => if (self.stage != .fragment) return invalid,
                        else => {},
                    }
                    length = operation.args.len;
                    @memcpy(operands[0..length], operation.args);
                },
                .extract => |operation| {
                    operands[0] = operation.value;
                    length = 1;
                    if (operation.value >= self.values.items.len) return invalid;
                    const aggregate = self.values.items[operation.value].typ;
                    const typ: Type = switch (aggregate) {
                        .cb_i32 => .i32,
                        .cb_f32 => .f32,
                        .res_f32 => if (operation.index == 4) .i32 else .f32,
                        else => return invalid,
                    };
                    if (operation.index >= (if (aggregate == .res_f32) @as(u32, 5) else 4) or value.typ != typ) return invalid;
                },
                .phi => |incoming| {
                    var expected: usize = 0;
                    for (0..count) |predecessor| if (predecessors[owner * count + predecessor]) {
                        expected += 1;
                    };
                    if (incoming.len != expected or expected == 0) return invalid;
                    for (incoming, 0..) |edge, index| {
                        if (!self.hasType(edge.value, value.typ) or edge.block >= count or !predecessors[owner * count + edge.block]) return invalid;
                        for (incoming[0..index]) |earlier| if (earlier.block == edge.block) return invalid;
                        if (owners[edge.value]) |definition| if (!dominators[edge.block * count + definition]) return invalid;
                    }
                },
            }
            for (operands[0..length]) |operand| {
                if (operand >= self.values.items.len) return invalid;
                if (owners[operand]) |definition| {
                    if (!dominators[owner * count + definition]) return invalid;
                    if (definition == owner and positions[operand] >= positions[value_index]) return invalid;
                }
            }
        }
        for (self.blocks.items, 0..) |block_value, block_index| if (block_value.terminator == .conditional) {
            const condition = block_value.terminator.conditional.condition;
            if (owners[condition]) |definition| if (!dominators[block_index * count + definition]) return invalid;
        };
    }

    fn hasType(self: *const Module, value: ValueId, typ: Type) bool {
        return value < self.values.items.len and self.values.items[value].typ == typ;
    }

    fn immediate(self: *const Module, value: ValueId) ?u32 {
        if (value >= self.values.items.len or self.values.items[value].instruction != .constant) return null;
        return self.values.items[value].instruction.constant;
    }
};

fn integerBits(typ: Type) u32 {
    return switch (typ) {
        .i1 => 1,
        .i8 => 8,
        .i32 => 32,
        else => 0,
    };
}

test "IR verifier rejects invalid signature access and impossible casts" {
    var module = Module.init(std.testing.allocator, .fragment);
    defer module.deinit();
    _ = try module.block();
    try module.outputs.append(std.testing.allocator, .{ .name = "SV_Target", .semantic = .target, .columns = 1 });
    const scalar = try module.float(1);
    const store = try module.intrinsic(.store_f32, &.{ try module.constant(.i32, 0), try module.constant(.i32, 0), try module.constant(.i8, 0), scalar });
    module.terminate(.ret);
    try module.verify(std.testing.allocator);
    const original = module.values.items[store].instruction.call.args;
    var args = try std.testing.allocator.dupe(ValueId, original);
    std.testing.allocator.free(original);
    module.values.items[store].instruction.call.args = args;
    args[3] = try module.constant(.i8, 3);
    try std.testing.expectError(error.InvalidIr, module.verify(std.testing.allocator));
    args[3] = try module.constant(.i8, 0);
    _ = try module.add(.i32, .{ .cast = .{ .op = .zext, .value = scalar } });
    try std.testing.expectError(error.InvalidIr, module.verify(std.testing.allocator));
}

test "IR verifier rejects invalid operands missing terminators and phi predecessors" {
    var module = Module.init(std.testing.allocator, .fragment);
    defer module.deinit();
    _ = try module.block();
    const scalar = try module.float(1);
    const integer = try module.constant(.i32, 2);
    try std.testing.expectError(error.InvalidIr, module.verify(std.testing.allocator));
    module.terminate(.ret);
    try module.verify(std.testing.allocator);
    const invalid = try module.binary(.add, scalar, integer);
    try std.testing.expectError(error.InvalidIr, module.verify(std.testing.allocator));
    module.values.items[invalid].instruction.binary.right = scalar;
    try module.verify(std.testing.allocator);
    const successor = try module.block();
    module.blocks.items[0].terminator = .{ .branch = successor };
    module.current = successor;
    _ = try module.phi(.f32, &.{.{ .value = scalar, .block = successor }});
    module.terminate(.ret);
    try std.testing.expectError(error.InvalidIr, module.verify(std.testing.allocator));
}
