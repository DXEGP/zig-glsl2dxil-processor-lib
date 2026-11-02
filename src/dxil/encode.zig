const std = @import("std");
const ir = @import("ir.zig");
const targets = @import("target.zig");
const Writer = @import("bitstream.zig").Writer;
const Record = struct { code: u32, operands: []const u64 };
const Constant = struct { typ: u32, record: Record };

const Builder = struct {
    allocator: std.mem.Allocator,
    types: std.ArrayList(Record) = .empty,
    constants: std.ArrayList(Constant) = .empty,
    metadata: std.ArrayList(Record) = .empty,
    functions: u32 = 1,
    type_names: std.AutoHashMapUnmanaged(u32, []const u8) = .empty,

    fn typeRecord(self: *Builder, code: u32, operands: []const u64) !u32 {
        const result: u32 = @intCast(self.types.items.len);
        try self.types.append(self.allocator, .{ .code = code, .operands = try self.allocator.dupe(u64, operands) });
        return result;
    }

    fn constant(self: *Builder, typ: u32, code: u32, operands: []const u64) !u32 {
        for (self.constants.items, 0..) |item, index| if (item.typ == typ and item.record.code == code and std.mem.eql(u64, item.record.operands, operands)) {
            return self.functions + @as(u32, @intCast(index));
        };
        const result = self.functions + @as(u32, @intCast(self.constants.items.len));
        try self.constants.append(self.allocator, .{ .typ = typ, .record = .{ .code = code, .operands = try self.allocator.dupe(u64, operands) } });
        return result;
    }

    fn namedStruct(self: *Builder, name: []const u8, operands: []const u64) !u32 {
        const typ = try self.typeRecord(20, operands);
        try self.type_names.put(self.allocator, typ, name);
        return typ;
    }

    fn scalar(self: *Builder, typ: ir.Type, bits: u32) !u32 {
        const encoded: u64 = if (typ == .f32) bits else if (typ == .i32) signed(@as(i32, @bitCast(bits))) else @as(u64, bits) << 1;
        return self.constant(@backingInt(typ), if (typ == .f32) 6 else 4, &.{encoded});
    }

    fn meta(self: *Builder, code: u32, operands: []const u64) !u32 {
        try self.metadata.append(self.allocator, .{ .code = code, .operands = try self.allocator.dupe(u64, operands) });
        return @intCast(self.metadata.items.len);
    }

    fn text(self: *Builder, name: []const u8) !u32 {
        const operands = try self.allocator.alloc(u64, name.len);
        for (name, operands) |byte, *operand| operand.* = byte;
        return self.meta(1, operands);
    }

    fn value(self: *Builder, typ: u32, id: u32) !u32 {
        return self.meta(2, &.{ typ, id });
    }
    fn integer(self: *Builder, typ: ir.Type, bits: u32) !u32 {
        return self.value(@backingInt(typ), try self.scalar(typ, bits));
    }

    fn signature(self: *Builder, elements: []const ir.Signature) !u32 {
        if (elements.len == 0) return 0;
        var nodes: std.ArrayList(u64) = .empty;
        for (elements, 0..) |element, index| {
            const indices = try self.meta(3, &.{try self.integer(.i32, element.index)});
            const usage = if (element.usage != 0) try self.meta(3, &.{ try self.integer(.i32, 3), try self.integer(.i32, element.usage) }) else 0;
            try nodes.append(self.allocator, try self.meta(3, &.{
                try self.integer(.i32, @intCast(index)),                           try self.text(element.name),
                try self.integer(.i8, switch (element.scalar) {
                    .float => 9,
                    .int => 4,
                    .uint => 5,
                }),
                try self.integer(.i8, @backingInt(element.semantic)),              indices,
                try self.integer(.i8, element.interpolation),                      try self.integer(.i32, 1),
                try self.integer(.i8, element.columns),                            try self.integer(.i32, element.row),
                try self.integer(.i8, if (element.semantic == .depth) 255 else 0), usage,
            }));
        }
        return self.meta(3, nodes.items);
    }
};

pub fn signed(number: i64) u64 {
    return if (number < 0) (@as(u64, @intCast(-number)) << 1) | 1 else @as(u64, @intCast(number)) << 1;
}

pub fn vectorCount(elements: []const ir.Signature) u32 {
    return (scalarCount(elements) + 3) / 4;
}

pub fn scalarCount(elements: []const ir.Signature) u32 {
    var count: u32 = 0;
    for (elements) |element| if (element.semantic != .depth) {
        count = @max(count, element.row * 4 + element.columns);
    };
    return count;
}

pub const Analysis = struct { inputs: []ir.Signature, outputs: []ir.Signature, input_count: u32, output_count: u32, dependencies: []u32 };

pub fn analyze(allocator: std.mem.Allocator, program: *const ir.Module) !Analysis {
    const inputs = try allocator.dupe(ir.Signature, program.inputs.items);
    const outputs = try allocator.dupe(ir.Signature, program.outputs.items);
    const input_count = scalarCount(inputs);
    const output_count = scalarCount(outputs);
    const output_words = (output_count + 31) / 32;
    const dependencies = try allocator.alloc(u32, input_count * output_words);
    @memset(dependencies, 0);
    const words = (input_count + 31) / 32;
    const value_dependencies = try allocator.alloc(u32, program.values.items.len * 4 * words);
    @memset(value_dependencies, 0);
    const block_dependencies = try allocator.alloc(u32, program.blocks.items.len * words);
    @memset(block_dependencies, 0);
    const owners = try allocator.alloc(usize, program.values.items.len);
    @memset(owners, 0);
    for (program.blocks.items, 0..) |block, block_index| for (block.values.items) |id| {
        owners[id] = block_index;
    };
    var changed = true;
    while (changed) {
        changed = false;
        for (program.blocks.items, 0..) |block, block_index| {
            const source = block_dependencies[block_index * words ..][0..words];
            switch (block.terminator) {
                .branch => |target| {
                    changed = merge(block_dependencies[target * words ..][0..words], source) or changed;
                },
                .conditional => |branch| {
                    for ([_]ir.BlockId{ branch.yes, branch.no }) |target| {
                        const destination = block_dependencies[target * words ..][0..words];
                        changed = merge(destination, source) or changed;
                        changed = merge(destination, value_dependencies[branch.condition * 4 * words ..][0..words]) or changed;
                    }
                },
                else => {},
            }
        }
        for (program.values.items, 0..) |value, value_index| for (0..value.typ.lanes()) |lane| {
            const destination = value_dependencies[(value_index * 4 + lane) * words ..][0..words];
            if (value.instruction != .constant and value.instruction != .undef and value.instruction != .aggregate)
                changed = merge(destination, block_dependencies[owners[value_index] * words ..][0..words]) or changed;
            switch (value.instruction) {
                .constant, .undef, .aggregate => {},
                .insert => |operation| {
                    const index = program.values.items[operation.index].instruction;
                    if (index == .constant) {
                        const operand = if (index.constant == lane) operation.value else operation.vector;
                        changed = merge(destination, laneDependencies(program, value_dependencies, words, operand, lane)) or changed;
                    } else {
                        for ([_]ir.ValueId{ operation.vector, operation.value, operation.index }) |operand| changed = merge(destination, laneDependencies(program, value_dependencies, words, operand, lane)) or changed;
                    }
                },
                .element => |operation| {
                    const index = program.values.items[operation.index].instruction;
                    if (index == .constant) {
                        changed = merge(destination, laneDependencies(program, value_dependencies, words, operation.vector, index.constant)) or changed;
                    } else {
                        changed = merge(destination, laneDependencies(program, value_dependencies, words, operation.index, 0)) or changed;
                        for (0..program.values.items[operation.vector].typ.lanes()) |component| changed = merge(destination, laneDependencies(program, value_dependencies, words, operation.vector, component)) or changed;
                    }
                },
                .call => |operation| {
                    if (operation.op == .load_f32 or operation.op == .load_i32) {
                        const element_id = program.values.items[operation.args[1]].instruction.constant;
                        const column = program.values.items[operation.args[3]].instruction.constant;
                        if (element_id < inputs.len and column < inputs[element_id].columns) {
                            inputs[element_id].usage |= @as(u8, 1) << @intCast(column);
                            const scalar = inputs[element_id].row * 4 + column;
                            const mask = @as(u32, 1) << @intCast(scalar % 32);
                            if (destination[scalar / 32] & mask == 0) {
                                destination[scalar / 32] |= mask;
                                changed = true;
                            }
                        }
                    } else {
                        for (operation.args) |operand| {
                            changed = merge(destination, laneDependencies(program, value_dependencies, words, operand, lane)) or changed;
                        }
                    }
                },
                .binary => |operation| {
                    changed = merge(destination, laneDependencies(program, value_dependencies, words, operation.left, lane)) or changed;
                    changed = merge(destination, laneDependencies(program, value_dependencies, words, operation.right, lane)) or changed;
                },
                .compare => |operation| {
                    changed = merge(destination, laneDependencies(program, value_dependencies, words, operation.left, lane)) or changed;
                    changed = merge(destination, laneDependencies(program, value_dependencies, words, operation.right, lane)) or changed;
                },
                .cast => |operation| {
                    changed = merge(destination, laneDependencies(program, value_dependencies, words, operation.value, lane)) or changed;
                },
                .extract => |operation| {
                    changed = merge(destination, laneDependencies(program, value_dependencies, words, operation.value, lane)) or changed;
                },
                .select => |operation| {
                    for ([_]ir.ValueId{ operation.condition, operation.yes, operation.no }) |operand| {
                        changed = merge(destination, laneDependencies(program, value_dependencies, words, operand, lane)) or changed;
                    }
                },
                .phi => |incoming| {
                    for (incoming) |edge| {
                        changed = merge(destination, laneDependencies(program, value_dependencies, words, edge.value, lane)) or changed;
                        changed = merge(destination, block_dependencies[edge.block * words ..][0..words]) or changed;
                    }
                },
            }
        };
    }
    for (program.values.items, 0..) |value, value_index| if (value.instruction == .call) {
        const operation = value.instruction.call;
        if (operation.op != .store_f32 and operation.op != .store_i32) continue;
        const element_id = program.values.items[operation.args[1]].instruction.constant;
        const column = program.values.items[operation.args[3]].instruction.constant;
        outputs[element_id].usage |= @as(u8, 1) << @intCast(column);
        if (outputs[element_id].semantic == .depth) continue;
        const output = outputs[element_id].row * 4 + column;
        const source = value_dependencies[value_index * 4 * words ..][0..words];
        for (0..input_count) |input| if (source[input / 32] & (@as(u32, 1) << @intCast(input % 32)) != 0) {
            dependencies[input * output_words + output / 32] |= @as(u32, 1) << @intCast(output % 32);
        };
    };
    return .{ .inputs = inputs, .outputs = outputs, .input_count = input_count, .output_count = output_count, .dependencies = dependencies };
}

fn laneDependencies(program: *const ir.Module, dependencies: []const u32, words: u32, id: ir.ValueId, lane: usize) []const u32 {
    const component = if (program.values.items[id].typ.lanes() > 1) lane else 0;
    return dependencies[(id * 4 + component) * words ..][0..words];
}

fn merge(destination: []u32, source: []const u32) bool {
    var changed = false;
    for (destination, source) |*target, bits| {
        if (target.* | bits != target.*) changed = true;
        target.* |= bits;
    }
    return changed;
}

pub fn emit(allocator: std.mem.Allocator, program: *const ir.Module, analysis: Analysis, target: targets.Target) ![]u8 {
    var builder: Builder = .{ .allocator = allocator };
    var function_ids: [@typeInfo(ir.Op).@"enum".field_names.len]u32 = @splat(0);
    var function_types: [@typeInfo(ir.Op).@"enum".field_names.len]u32 = @splat(0);
    for (program.values.items) |value| if (value.instruction == .call) {
        const index = @backingInt(value.instruction.call.op);
        if (function_ids[index] == 0) {
            function_ids[index] = builder.functions;
            builder.functions += 1;
        }
    };
    _ = try builder.typeRecord(2, &.{});
    _ = try builder.typeRecord(7, &.{1});
    _ = try builder.typeRecord(7, &.{8});
    _ = try builder.typeRecord(7, &.{32});
    _ = try builder.typeRecord(3, &.{});
    _ = try builder.typeRecord(8, &.{ 2, 0 });
    _ = try builder.typeRecord(20, &.{ 0, 5 });
    _ = try builder.typeRecord(20, &.{ 0, 4, 4, 4, 4 });
    _ = try builder.typeRecord(20, &.{ 0, 3, 3, 3, 3 });
    _ = try builder.typeRecord(20, &.{ 0, 4, 4, 4, 4, 3 });
    _ = try builder.namedStruct("dx.types.ResBind", &.{ 0, 3, 3, 3, 2 });
    _ = try builder.namedStruct("dx.types.ResourceProperties", &.{ 0, 3, 3 });
    for ([_]ir.Type{ .f32x2, .f32x3, .f32x4, .i32x2, .i32x3, .i32x4 }) |typ| _ = try builder.typeRecord(12, &.{ typ.lanes(), @backingInt(typ.scalar()) });
    _ = try builder.typeRecord(7, &.{64});
    const entry_type = try builder.typeRecord(21, &.{ 0, 0 });
    const entry_pointer = try builder.typeRecord(8, &.{ entry_type, 0 });
    for (std.enums.values(ir.Op)) |op| {
        const index = @backingInt(op);
        if (function_ids[index] == 0) continue;
        const definition = op.definition();
        var operands: [18]u64 = undefined;
        operands[0] = 0;
        operands[1] = @backingInt(definition.ret);
        for (definition.params, 0..) |typ, parameter| operands[parameter + 2] = @backingInt(typ);
        function_types[index] = try builder.typeRecord(21, operands[0 .. definition.params.len + 2]);
    }
    const value_ids = try allocator.alloc(u32, program.values.items.len);
    @memset(value_ids, 0);
    for (program.values.items, 0..) |value, index| switch (value.instruction) {
        .constant => |bits| value_ids[index] = try builder.scalar(value.typ, bits),
        .undef => value_ids[index] = try builder.constant(@backingInt(value.typ), 3, &.{}),
        .aggregate => |fields| {
            var operands: [4]u64 = undefined;
            const length: usize = if (value.typ == .res_binding) 4 else 2;
            for (fields[0..length], 0..) |field, field_index| operands[field_index] = try builder.scalar(if (value.typ == .res_binding and field_index == 3) .i8 else .i32, field);
            value_ids[index] = try builder.constant(@backingInt(value.typ), 7, operands[0..length]);
        },
        else => {},
    };
    const version = try builder.meta(3, &.{ try builder.integer(.i32, 1), try builder.integer(.i32, target.minor()) });
    const shader_model = try builder.meta(3, &.{ try builder.text(if (program.stage == .vertex) "vs" else "ps"), try builder.integer(.i32, 6), try builder.integer(.i32, target.minor()) });
    const signatures = try builder.meta(3, &.{ try builder.signature(analysis.inputs), try builder.signature(analysis.outputs), 0 });
    var resource_lists: [4]std.ArrayList(u64) = @splat(.empty);
    for (program.resources.items) |resource| {
        var resource_type: u32 = undefined;
        switch (resource.class) {
            .cbuffer => {
                const array_type = try builder.typeRecord(11, &.{ resource.size / 4, @backingInt(ir.Type.f32) });
                resource_type = try builder.namedStruct(resource.name, &.{ 0, array_type });
            },
            .srv => {
                const vector = try builder.typeRecord(12, &.{ 4, @backingInt(ir.Type.f32) });
                resource_type = try builder.typeRecord(18, &.{ 0, vector });
            },
            .sampler => resource_type = try builder.typeRecord(18, &.{ 0, @backingInt(ir.Type.i32) }),
            .uav => return error.InvalidIr,
        }
        const pointer = try builder.typeRecord(8, &.{ resource_type, 0 });
        const symbol = try builder.value(pointer, try builder.constant(pointer, 3, &.{}));
        const resource_class = @backingInt(resource.class);
        var operands: std.ArrayList(u64) = .empty;
        try operands.appendSlice(allocator, &.{ try builder.integer(.i32, @intCast(resource_lists[resource_class].items.len)), symbol, try builder.text(resource.name), try builder.integer(.i32, resource.space), try builder.integer(.i32, resource.binding), try builder.integer(.i32, 1) });
        switch (resource.class) {
            .cbuffer => try operands.appendSlice(allocator, &.{ try builder.integer(.i32, resource.size), 0 }),
            .sampler => try operands.appendSlice(allocator, &.{ try builder.integer(.i32, 0), 0 }),
            .srv => try operands.appendSlice(allocator, &.{ try builder.integer(.i32, 2), try builder.integer(.i32, 0), try builder.meta(3, &.{ try builder.integer(.i32, 0), try builder.integer(.i32, 9) }) }),
            .uav => unreachable,
        }
        try resource_lists[resource_class].append(allocator, try builder.meta(3, operands.items));
    }
    var resource_nodes: [4]u64 = @splat(0);
    for (&resource_lists, &resource_nodes) |*list, *node| if (list.items.len != 0) {
        node.* = try builder.meta(3, list.items);
    };
    const resources = if (program.resources.items.len != 0) try builder.meta(3, &resource_nodes) else 0;
    const features = targets.requirements(program, target).feature_flags;
    const raw_flags = features << 5;
    const flags = if (raw_flags != 0) try builder.meta(3, &.{ try builder.integer(.i32, 0), try builder.value(@backingInt(ir.Type.i64), try builder.constant(@backingInt(ir.Type.i64), 4, &.{raw_flags << 1})) }) else 0;
    const entry = try builder.meta(3, &.{ try builder.value(entry_pointer, 0), try builder.text("main"), signatures, resources, flags });
    var view_values: std.ArrayList(u64) = .empty;
    try view_values.append(allocator, try builder.scalar(.i32, analysis.input_count));
    try view_values.append(allocator, try builder.scalar(.i32, analysis.output_count));
    for (analysis.dependencies) |bits| try view_values.append(allocator, try builder.scalar(.i32, bits));
    const view_type = try builder.typeRecord(11, &.{ view_values.items.len, @backingInt(ir.Type.i32) });
    const view_constant = try builder.constant(view_type, 7, view_values.items);
    const view_state = try builder.meta(3, &.{try builder.value(view_type, view_constant)});
    var next_value: u32 = builder.functions + @as(u32, @intCast(builder.constants.items.len));
    for (program.blocks.items) |block| for (block.values.items) |id| {
        value_ids[id] = next_value;
        if (program.values.items[id].typ != .void_) next_value += 1;
    };
    var writer = Writer.init(allocator);
    errdefer writer.deinit();
    try writer.bits(0xdec04342, 32);
    const module_block = try writer.begin(8);
    try writer.record(1, &.{1});
    const types_block = try writer.begin(17);
    try writer.record(1, &.{builder.types.items.len});
    for (builder.types.items, 0..) |record, index| {
        const name: ?[]const u8 = switch (index) {
            6 => "dx.types.Handle",
            7 => "dx.types.CBufRet.f32",
            8 => "dx.types.CBufRet.i32",
            9 => "dx.types.ResRet.f32",
            else => builder.type_names.get(@intCast(index)),
        };
        if (name) |text| try writer.textRecord(19, &.{}, text);
        try writer.record(record.code, record.operands);
    }
    try writer.end(types_block);
    const attribute_groups = try writer.begin(10);
    try writer.record(3, &.{ 1, 0xffffffff, 0, 18 });
    try writer.record(3, &.{ 2, 0xffffffff, 0, 18, 0, 20 });
    try writer.record(3, &.{ 3, 0xffffffff, 0, 18, 0, 21 });
    try writer.end(attribute_groups);
    const attributes = try writer.begin(9);
    try writer.record(2, &.{1});
    try writer.record(2, &.{2});
    try writer.record(2, &.{3});
    try writer.end(attributes);
    try writer.textRecord(2, &.{}, "dxil-ms-dx");
    try writer.textRecord(3, &.{}, "e-m:e-p:32:32-i1:32-i8:32-i16:32-i32:32-i64:64-f16:32-f32:32-f64:64-n8:16:32:64");
    try writer.record(8, &.{ entry_type, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 });
    var function_index: u32 = 1;
    while (function_index < builder.functions) : (function_index += 1) {
        for (std.enums.values(ir.Op)) |op| {
            if (function_ids[@backingInt(op)] != function_index) continue;
            const attribute: u32 = switch (op.definition().memory) {
                .none => 2,
                .read => 3,
                .write => 1,
            };
            try writer.record(8, &.{ function_types[@backingInt(op)], 0, 1, 0, attribute, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 });
        }
    }
    const constants_block = try writer.begin(11);
    for (builder.constants.items) |constant| {
        try writer.record(1, &.{constant.typ});
        try writer.record(constant.record.code, constant.record.operands);
    }
    try writer.end(constants_block);
    const metadata_block = try writer.begin(15);
    for (builder.metadata.items) |record| try writer.record(record.code, record.operands);
    const names = [_][]const u8{ "dx.version", "dx.valver", "dx.shaderModel", "dx.entryPoints", "dx.viewIdState" };
    for (names, [_]u32{ version, version, shader_model, entry, view_state }) |name, node| {
        try writer.textRecord(4, &.{}, name);
        try writer.record(10, &.{node - 1});
    }
    if (resources != 0) {
        try writer.textRecord(4, &.{}, "dx.resources");
        try writer.record(10, &.{resources - 1});
    }
    try writer.end(metadata_block);
    const symbols = try writer.begin(14);
    try writer.textRecord(1, &.{0}, "main");
    for (std.enums.values(ir.Op)) |op| if (function_ids[@backingInt(op)] != 0) {
        try writer.textRecord(1, &.{function_ids[@backingInt(op)]}, op.definition().name);
    };
    try writer.end(symbols);
    const function_block = try writer.begin(12);
    try writer.record(1, &.{program.blocks.items.len});
    next_value = builder.functions + @as(u32, @intCast(builder.constants.items.len));
    for (program.blocks.items) |block| {
        for (block.values.items) |id| {
            const value = program.values.items[id];
            var operands: std.ArrayList(u64) = .empty;
            const code: u32 = switch (value.instruction) {
                .constant, .undef, .aggregate => unreachable,
                .insert => |operation| code: {
                    try pushValue(&operands, allocator, program, value_ids, next_value, operation.vector, true);
                    try pushValue(&operands, allocator, program, value_ids, next_value, operation.value, true);
                    try pushValue(&operands, allocator, program, value_ids, next_value, operation.index, true);
                    break :code 7;
                },
                .element => |operation| code: {
                    try pushValue(&operands, allocator, program, value_ids, next_value, operation.vector, true);
                    try pushValue(&operands, allocator, program, value_ids, next_value, operation.index, true);
                    break :code 6;
                },
                .binary => |operation| code: {
                    try pushValue(&operands, allocator, program, value_ids, next_value, operation.left, true);
                    try pushValue(&operands, allocator, program, value_ids, next_value, operation.right, false);
                    try operands.append(allocator, switch (operation.op) {
                        .add => 0,
                        .sub => 1,
                        .mul => 2,
                        .udiv => 3,
                        .sdiv, .fdiv => 4,
                        .urem => 5,
                        .srem => 6,
                        .shl => 7,
                        .lshr => 8,
                        .ashr => 9,
                        .and_ => 10,
                        .or_ => 11,
                        .xor_ => 12,
                    });
                    break :code 2;
                },
                .compare => |operation| code: {
                    try pushValue(&operands, allocator, program, value_ids, next_value, operation.left, true);
                    try pushValue(&operands, allocator, program, value_ids, next_value, operation.right, false);
                    try operands.append(allocator, switch (operation.predicate) {
                        .eq => 32,
                        .ne => 33,
                        .ugt => 34,
                        .uge => 35,
                        .ult => 36,
                        .ule => 37,
                        .sgt => 38,
                        .sge => 39,
                        .slt => 40,
                        .sle => 41,
                        .oeq => 1,
                        .ogt => 2,
                        .oge => 3,
                        .olt => 4,
                        .ole => 5,
                        .one => 6,
                        .une => 14,
                    });
                    break :code 28;
                },
                .cast => |operation| code: {
                    try pushValue(&operands, allocator, program, value_ids, next_value, operation.value, true);
                    try operands.appendSlice(allocator, &.{ @backingInt(value.typ), switch (operation.op) {
                        .trunc => 0,
                        .zext => 1,
                        .sext => 2,
                        .fptoui => 3,
                        .fptosi => 4,
                        .uitofp => 5,
                        .sitofp => 6,
                        .bitcast => 11,
                    } });
                    break :code 3;
                },
                .select => |operation| code: {
                    try pushValue(&operands, allocator, program, value_ids, next_value, operation.yes, true);
                    try pushValue(&operands, allocator, program, value_ids, next_value, operation.no, false);
                    try pushValue(&operands, allocator, program, value_ids, next_value, operation.condition, true);
                    break :code 29;
                },
                .phi => |incoming| code: {
                    try operands.append(allocator, @backingInt(value.typ));
                    for (incoming) |edge| try operands.appendSlice(allocator, &.{ signed(@as(i64, next_value) - @as(i64, value_ids[edge.value])), edge.block });
                    break :code 16;
                },
                .extract => |operation| code: {
                    try pushValue(&operands, allocator, program, value_ids, next_value, operation.value, true);
                    try operands.append(allocator, operation.index);
                    break :code 26;
                },
                .call => |operation| code: {
                    const index = @backingInt(operation.op);
                    try operands.appendSlice(allocator, &.{ 0, 1 << 15, function_types[index], next_value - function_ids[index] });
                    for (operation.args) |arg| try pushValue(&operands, allocator, program, value_ids, next_value, arg, false);
                    break :code 34;
                },
            };
            try writer.record(code, operands.items);
            if (value.typ != .void_) next_value += 1;
        }
        switch (block.terminator) {
            .none => return error.InvalidIr,
            .ret => try writer.record(10, &.{}),
            .branch => |destination| try writer.record(11, &.{destination}),
            .conditional => |branch| try writer.record(11, &.{ branch.yes, branch.no, next_value -% value_ids[branch.condition] }),
        }
    }
    try writer.end(function_block);
    try writer.end(module_block);
    return writer.bytes.toOwnedSlice(allocator);
}

fn pushValue(operands: *std.ArrayList(u64), allocator: std.mem.Allocator, program: *const ir.Module, ids: []const u32, next: u32, value: ir.ValueId, typed: bool) !void {
    try operands.append(allocator, next -% ids[value]);
    if (typed and ids[value] >= next) try operands.append(allocator, @backingInt(program.values.items[value].typ));
}

test "native vector dependencies retain per lane input precision" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var program = ir.Module.init(allocator, .fragment);
    _ = try program.block();
    try program.inputs.append(allocator, .{ .name = "TEXCOORD", .columns = 3, .interpolation = 2 });
    try program.outputs.append(allocator, .{ .name = "SV_Target", .semantic = .target, .columns = 1 });
    var vector = try program.undef(.f32x3);
    for (0..3) |component| {
        const input = try program.intrinsic(.load_f32, &.{ try program.constant(.i32, 0), try program.constant(.i32, 0), try program.constant(.i8, @intCast(component)), try program.undef(.i32) });
        vector = try program.add(.f32x3, .{ .insert = .{ .vector = vector, .value = input, .index = try program.constant(.i32, @intCast(component)) } });
    }
    const sum = try program.binary(.add, vector, vector);
    const scalar = try program.add(.f32, .{ .element = .{ .vector = sum, .index = try program.constant(.i32, 1) } });
    _ = try program.intrinsic(.store_f32, &.{ try program.constant(.i32, 0), try program.constant(.i32, 0), try program.constant(.i8, 0), scalar });
    program.terminate(.ret);
    try program.verify(allocator);
    const analysis = try analyze(allocator, &program);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 0 }, analysis.dependencies);
}
