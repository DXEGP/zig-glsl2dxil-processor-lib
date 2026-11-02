const std = @import("std");
const ast = @import("../glsl/ast.zig");
const sema = @import("sema.zig");
const ir = @import("ir.zig");
const Error = sema.Error;
const Value = struct { typ: sema.Type, parts: []const ir.ValueId };
const Variable = struct { name: []const u8, typ: sema.Type, slot: u32, readonly: bool = false, global: bool = false };
const LValue = struct { variable: usize, typ: sema.Type, indices: []const u32 };
const BlockState = struct {
    definitions: std.AutoHashMapUnmanaged(u32, ir.ValueId) = .empty,
    incomplete: std.AutoHashMapUnmanaged(u32, ir.ValueId) = .empty,
    predecessors: std.ArrayList(ir.BlockId) = .empty,
    sealed: bool = false,
};
const Frame = struct { start: usize, return_block: ir.BlockId, return_value: ?usize, return_type: sema.Type };

pub const Lowerer = struct {
    allocator: std.mem.Allocator,
    program: *sema.Program,
    stage_index: usize,
    module: ir.Module,
    blocks: std.ArrayList(BlockState) = .empty,
    variables: std.ArrayList(Variable) = .empty,
    slot_types: std.ArrayList(ir.Type) = .empty,
    frame: ?Frame = null,
    calls: std.ArrayList([]const u8) = .empty,
    break_target: ?ir.BlockId = null,
    continue_target: ?ir.BlockId = null,
    handles: std.ArrayList(ir.ValueId) = .empty,
    position: ?usize = null,
    scope_start: usize = 0,
    frag_color: ?usize = null,
    frag_depth: ?usize = null,
    uses_frag_color: bool = false,
    uses_frag_depth: bool = false,
    validation_entry: ?[]const u8 = null,
    source_location: ast.Location = .{ .line = 1, .column = 1 },
    expression_depth: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, program: *sema.Program, stage_index: usize) Lowerer {
        return .{ .allocator = allocator, .program = program, .stage_index = stage_index, .module = ir.Module.init(allocator, if (stage_index == 0) .vertex else .fragment) };
    }

    pub fn lower(self: *Lowerer) Error!ir.Module {
        _ = try self.newBlock();
        self.blocks.items[0].sealed = true;
        self.program.context(self.stage_index);
        const stage = &self.program.stages[self.stage_index];
        if (self.stage_index == 0) {
            try self.module.outputs.append(self.allocator, .{ .name = "SV_Position", .semantic = .position, .interpolation = 4 });
            self.position = try self.variable("gl_Position", .{ .rows = 4 }, false, true);
        } else {
            self.frag_color = try self.variable("gl_FragColor", .{ .rows = 4 }, false, true);
            self.frag_depth = try self.variable("gl_FragDepth", .{}, false, true);
        }
        for (stage.globals.items) |*global| {
            switch (global.kind) {
                .input, .output => {
                    const input = global.kind == .input;
                    const signature = ir.Signature{
                        .name = if (self.stage_index == 1 and !input) "SV_Target" else "TEXCOORD",
                        .index = global.location.?,
                        .row = if ((self.stage_index == 0 and !input) or (self.stage_index == 1 and input)) global.row else if (input) @intCast(self.module.inputs.items.len) else global.location.?,
                        .columns = global.typ.rows,
                        .scalar = switch (global.typ.scalar) {
                            .int => .int,
                            .uint => .uint,
                            else => .float,
                        },
                        .semantic = if (self.stage_index == 1 and !input) .target else .arbitrary,
                        .interpolation = if ((self.stage_index == 0 and input) or (self.stage_index == 1 and !input)) 0 else switch (global.decl.qualifiers.interpolation orelse .smooth) {
                            .smooth => 2,
                            .flat => 1,
                            .noperspective => 4,
                        },
                    };
                    global.signature = @intCast(if (input) self.module.inputs.items.len else self.module.outputs.items.len);
                    if (input) try self.module.inputs.append(self.allocator, signature) else try self.module.outputs.append(self.allocator, signature);
                    const variable_index = try self.variable(global.decl.name, global.typ, input, true);
                    if (input) try self.write(variable_index, try self.loadInput(global.signature.?, global.typ));
                },
                .uniform => {},
                .constant, .plain => {
                    _ = try self.variable(global.decl.name, global.typ, global.kind == .constant, true);
                },
            }
        }
        for (self.program.bindings.items) |binding| {
            if (binding.stages & (@as(u32, 1) << @intCast(self.stage_index)) == 0) continue;
            var range: u32 = 0;
            for (self.module.resources.items) |existing| if (existing.class == binding.class) {
                range += 1;
            };
            try self.module.resources.append(self.allocator, .{ .name = binding.name, .class = binding.class, .binding = binding.binding, .space = binding.space, .size = binding.size });
            const handle = try self.module.intrinsic(.create_handle, &.{ try self.integer(.i8, @backingInt(binding.class)), try self.integer(.i32, range), try self.integer(.i32, binding.binding), try self.integer(.i1, 0) });
            try self.handles.append(self.allocator, handle);
        }
        for (stage.globals.items) |global| if (global.kind == .constant or global.kind == .plain) {
            if (global.decl.initializer) |initializer| {
                const result = try self.convert(try self.expression(initializer), global.typ, false, global.decl.line);
                try self.write(self.findVariable(global.decl.name).?, result);
            } else if (global.kind == .constant) return self.fail(global.decl.line, "const requires an initializer", .{});
        };
        var arguments: std.ArrayList(*ast.Expr) = .empty;
        if (self.validation_entry) |entry| for (stage.unit.decls) |declaration| {
            if (declaration.* != .function or declaration.function.body == null or !std.mem.eql(u8, declaration.function.name, entry)) continue;
            for (declaration.function.params, 0..) |parameter, index| {
                var typ = try self.program.resolveType(self.stage_index, parameter.typ);
                if (parameter.array_len) |length| typ.array_len = try self.program.arrayLength(self.stage_index, length);
                const name = try std.fmt.allocPrint(self.allocator, "$argument{d}", .{index});
                _ = try self.variable(name, typ, false, true);
                const expression_node = try self.allocator.create(ast.Expr);
                expression_node.* = .{ .identifier = .{ .name = name, .line = declaration.function.line, .column = declaration.function.column } };
                try arguments.append(self.allocator, expression_node);
            }
            break;
        };
        _ = try self.userCall(.{ .callee = self.validation_entry orelse "main", .args = arguments.items, .line = 1, .column = 1 });
        if (self.position) |position| {
            if (self.program.opengl) {
                var value = try self.read(position);
                const parts = try self.allocator.dupe(ir.ValueId, value.parts);
                parts[1] = try self.module.binary(.mul, parts[1], try self.compatFloat(0));
                parts[2] = try self.module.binary(.add, try self.module.binary(.mul, parts[2], try self.compatFloat(1)), try self.module.binary(.mul, parts[3], try self.compatFloat(2)));
                value.parts = parts;
                try self.write(position, value);
            }
        }
        if (self.position) |position| try self.storeOutput(0, try self.read(position));
        for (stage.globals.items) |global| if (global.kind == .output) {
            try self.storeOutput(global.signature.?, try self.read(self.findVariable(global.decl.name).?));
        };
        if (self.uses_frag_color) try self.storeOutput(try self.builtinOutput(.target), try self.read(self.frag_color.?));
        if (self.uses_frag_depth) try self.storeOutput(try self.builtinOutput(.depth), try self.read(self.frag_depth.?));
        if (!self.terminated()) self.module.terminate(.ret);
        return self.module;
    }

    fn newBlock(self: *Lowerer) Error!ir.BlockId {
        if (self.module.blocks.items.len >= 4096 or self.module.values.items.len >= 1000000) return self.fail(1, "shader exceeds IR resource limits", .{});
        const id = try self.module.block();
        try self.blocks.append(self.allocator, .{});
        return id;
    }

    fn edge(self: *Lowerer, target: ir.BlockId) Error!void {
        const predecessors = &self.blocks.items[target].predecessors;
        if (std.mem.indexOfScalar(ir.BlockId, predecessors.items, self.module.current) == null) try predecessors.append(self.allocator, self.module.current);
    }

    fn branch(self: *Lowerer, target: ir.BlockId) Error!void {
        try self.edge(target);
        self.module.terminate(.{ .branch = target });
    }

    fn conditional(self: *Lowerer, operand: ir.ValueId, yes: ir.BlockId, no: ir.BlockId) Error!void {
        try self.edge(yes);
        try self.edge(no);
        self.module.terminate(.{ .conditional = .{ .condition = operand, .yes = yes, .no = no } });
    }

    fn terminated(self: *Lowerer) bool {
        return self.module.blocks.items[self.module.current].terminator != .none;
    }

    fn seal(self: *Lowerer, block: ir.BlockId) Error!void {
        self.blocks.items[block].sealed = true;
        var iterator = self.blocks.items[block].incomplete.iterator();
        while (iterator.next()) |entry| try self.completePhi(entry.value_ptr.*, entry.key_ptr.*, block);
        self.blocks.items[block].incomplete.clearRetainingCapacity();
    }

    fn readSlot(self: *Lowerer, slot: u32, block: ir.BlockId) Error!ir.ValueId {
        if (self.blocks.items[block].definitions.get(slot)) |value| return value;
        const value = if (!self.blocks.items[block].sealed) value: {
            const phi = try self.newPhi(self.slot_types.items[slot], block);
            try self.blocks.items[block].definitions.put(self.allocator, slot, phi);
            try self.blocks.items[block].incomplete.put(self.allocator, slot, phi);
            break :value phi;
        } else if (self.blocks.items[block].predecessors.items.len == 0) try self.module.undef(self.slot_types.items[slot]) else if (self.blocks.items[block].predecessors.items.len == 1) try self.readSlot(slot, self.blocks.items[block].predecessors.items[0]) else value: {
            const phi = try self.newPhi(self.slot_types.items[slot], block);
            try self.blocks.items[block].definitions.put(self.allocator, slot, phi);
            try self.completePhi(phi, slot, block);
            break :value phi;
        };
        try self.blocks.items[block].definitions.put(self.allocator, slot, value);
        return value;
    }

    fn newPhi(self: *Lowerer, typ: ir.Type, block: ir.BlockId) Error!ir.ValueId {
        const current = self.module.current;
        self.module.current = block;
        const phi = try self.module.phi(typ, &.{});
        const values = &self.module.blocks.items[block].values;
        var index = values.items.len - 1;
        while (index > 0 and self.module.values.items[values.items[index - 1]].instruction != .phi) : (index -= 1) values.items[index] = values.items[index - 1];
        values.items[index] = phi;
        self.module.current = current;
        return phi;
    }

    fn completePhi(self: *Lowerer, phi: ir.ValueId, slot: u32, block: ir.BlockId) Error!void {
        const predecessors = self.blocks.items[block].predecessors.items;
        const incoming = try self.allocator.alloc(ir.Incoming, predecessors.len);
        for (predecessors, incoming) |predecessor, *edge_value| edge_value.* = .{ .value = try self.readSlot(slot, predecessor), .block = predecessor };
        self.allocator.free(self.module.values.items[phi].instruction.phi);
        self.module.values.items[phi].instruction.phi = incoming;
    }

    fn variable(self: *Lowerer, name: []const u8, typ: sema.Type, readonly: bool, global: bool) Error!usize {
        const index = self.variables.items.len;
        const slot: u32 = @intCast(self.slot_types.items.len);
        const count = self.program.componentCount(typ);
        if (count > 16384) return self.fail(1, "local aggregate exceeds resource limit", .{});
        for (0..count) |_| try self.slot_types.append(self.allocator, typ.irType());
        try self.variables.append(self.allocator, .{ .name = name, .typ = typ, .slot = slot, .readonly = readonly, .global = global });
        if (typ.scalar == .structure) {
            var component: usize = 0;
            try self.componentTypes(typ, self.slot_types.items[slot .. slot + count], &component);
        }
        return index;
    }

    fn componentTypes(self: *Lowerer, typ: sema.Type, result: []ir.Type, offset: *usize) Error!void {
        if (typ.array_len != 0) {
            for (0..typ.array_len) |_| try self.componentTypes(typ.element(), result, offset);
            return;
        }
        if (typ.scalar == .structure) {
            for (self.program.structures.items[typ.structure].fields) |field| try self.componentTypes(field.typ, result, offset);
            return;
        }
        for (0..typ.count()) |_| {
            result[offset.*] = typ.irType();
            offset.* += 1;
        }
    }

    fn findVariable(self: *Lowerer, name: []const u8) ?usize {
        var index = self.variables.items.len;
        while (index > 0) {
            index -= 1;
            const value = self.variables.items[index];
            if ((value.global or self.frame == null or index >= self.frame.?.start) and std.mem.eql(u8, value.name, name)) return index;
        }
        return null;
    }

    fn findGlobal(self: *Lowerer, name: []const u8) ?*sema.Global {
        for (self.program.stages[self.stage_index].globals.items) |*global| if (std.mem.eql(u8, global.decl.name, name)) return global;
        return null;
    }

    fn read(self: *Lowerer, variable_index: usize) Error!Value {
        const value = self.variables.items[variable_index];
        const count = self.program.componentCount(value.typ);
        const parts = try self.allocator.alloc(ir.ValueId, count);
        for (parts, 0..) |*part, index| part.* = try self.readSlot(value.slot + @as(u32, @intCast(index)), self.module.current);
        return .{ .typ = value.typ, .parts = parts };
    }

    fn write(self: *Lowerer, variable_index: usize, value: Value) Error!void {
        const variable_value = self.variables.items[variable_index];
        for (value.parts, 0..) |part, index| try self.blocks.items[self.module.current].definitions.put(self.allocator, variable_value.slot + @as(u32, @intCast(index)), part);
    }

    fn integer(self: *Lowerer, typ: ir.Type, bits: u32) Error!ir.ValueId {
        return self.module.constant(typ, bits);
    }

    fn loadInput(self: *Lowerer, signature: u32, typ: sema.Type) Error!Value {
        const parts = try self.allocator.alloc(ir.ValueId, typ.count());
        for (parts, 0..) |*part, index| part.* = try self.module.intrinsic(if (typ.scalar == .float) .load_f32 else .load_i32, &.{ try self.integer(.i32, signature), try self.integer(.i32, 0), try self.integer(.i8, @intCast(index)), try self.module.undef(.i32) });
        return .{ .typ = typ, .parts = parts };
    }

    fn storeOutput(self: *Lowerer, signature: u32, value: Value) Error!void {
        for (value.parts, 0..) |part, index| _ = try self.module.intrinsic(if (value.typ.scalar == .float) .store_f32 else .store_i32, &.{ try self.integer(.i32, signature), try self.integer(.i32, 0), try self.integer(.i8, @intCast(index)), part });
    }

    fn builtinOutput(self: *Lowerer, semantic: ir.Semantic) Error!u32 {
        for (self.module.outputs.items, 0..) |output, index| if (output.semantic == semantic) return @intCast(index);
        if (semantic == .target) for (self.module.outputs.items) |output| {
            if (output.semantic == .target and output.index == 0) return self.fail(1, "gl_FragColor conflicts with fragment output location 0", .{});
        };
        const id: u32 = @intCast(self.module.outputs.items.len);
        try self.module.outputs.append(self.allocator, .{ .name = if (semantic == .depth) "SV_Depth" else "SV_Target", .columns = if (semantic == .depth) 1 else 4, .semantic = semantic, .row = if (semantic == .depth) 0xffffffff else 0 });
        return id;
    }

    fn compatFloat(self: *Lowerer, component: u32) Error!ir.ValueId {
        return self.bufferScalar("GlCompat", component * 4, .float);
    }

    fn bufferScalar(self: *Lowerer, name: []const u8, offset: u32, scalar: sema.Scalar) Error!ir.ValueId {
        for (self.module.resources.items, 0..) |resource, index| if (resource.class == .cbuffer and std.mem.eql(u8, resource.name, name)) {
            const aggregate = try self.module.intrinsic(if (scalar == .float) .cbuffer_f32 else .cbuffer_i32, &.{ self.handles.items[index], try self.integer(.i32, offset / 16) });
            const value = try self.module.add(if (scalar == .float) .f32 else .i32, .{ .extract = .{ .value = aggregate, .index = offset % 16 / 4 } });
            return if (scalar == .bool_) self.module.compare(.ne, value, try self.integer(.i32, 0)) else value;
        };
        return self.fail(1, "missing constant buffer", .{});
    }

    fn expression(self: *Lowerer, node: *ast.Expr) Error!Value {
        if (self.expression_depth >= 256 or self.module.values.items.len >= 1000000) return self.fail(node.line(), "expression exceeds IR resource limit", .{});
        self.expression_depth += 1;
        defer self.expression_depth -= 1;
        const previous_location = self.source_location;
        self.source_location = self.program.stages[self.stage_index].unit.expression_locations.get(node) orelse previous_location;
        defer self.source_location = previous_location;
        return switch (node.*) {
            .float_literal => |text| self.single(.{ .scalar = .float }, try self.module.float(std.fmt.parseFloat(f32, std.mem.trimEnd(u8, text, "fF")) catch return self.fail(node.line(), "invalid float literal", .{}))),
            .int_literal => |text| self.single(.{ .scalar = .int }, try self.integer(.i32, @bitCast(std.fmt.parseInt(i32, text, 0) catch return self.fail(node.line(), "integer literal is outside int32", .{})))),
            .uint_literal => |text| self.single(.{ .scalar = .uint }, try self.integer(.i32, std.fmt.parseInt(u32, std.mem.trimEnd(u8, text, "uU"), 0) catch return self.fail(node.line(), "integer literal is outside uint32", .{}))),
            .bool_literal => |boolean| self.single(.{ .scalar = .bool_ }, try self.integer(.i1, @intFromBool(boolean))),
            .identifier => |identifier| value: {
                try self.markBuiltinOutput(identifier.name, identifier.line);
                if (self.findVariable(identifier.name)) |variable_index| break :value self.read(variable_index);
                if (self.findGlobal(identifier.name)) |global| {
                    if (global.kind == .uniform and global.typ.scalar != .sampler) break :value self.uniform(global.typ, global.offset);
                }
                if (std.mem.startsWith(u8, identifier.name, "gl_")) break :value self.builtin(identifier.name, identifier.line);
                break :value self.fail(identifier.line, "unknown identifier '{s}'", .{identifier.name});
            },
            .member => |member| value: {
                const base = try self.expression(member.base);
                if (base.typ.scalar == .structure) {
                    var offset: usize = 0;
                    for (self.program.structures.items[base.typ.structure].fields) |field| {
                        const count = self.program.componentCount(field.typ);
                        if (std.mem.eql(u8, field.name, member.name)) break :value .{ .typ = field.typ, .parts = base.parts[offset .. offset + count] };
                        offset += count;
                    }
                    return self.fail(member.line, "unknown field '{s}'", .{member.name});
                }
                const indices = try self.swizzle(base.typ, member.name, member.line);
                const parts = try self.allocator.alloc(ir.ValueId, indices.len);
                for (indices, parts) |index, *part| part.* = base.parts[index];
                break :value .{ .typ = .{ .scalar = base.typ.scalar, .rows = @intCast(parts.len) }, .parts = parts };
            },
            .index => |index| value: {
                const base = try self.expression(index.base);
                if (base.typ.array_len == 0 and base.typ.cols == 1 and base.typ.rows == 1) return self.fail(index.line, "indexing requires an aggregate", .{});
                const subscript = try self.expression(index.index);
                if (subscript.typ.rows != 1 or subscript.typ.cols != 1 or (subscript.typ.scalar != .int and subscript.typ.scalar != .uint)) return self.fail(index.line, "index must be an integer scalar", .{});
                const typ = base.typ.element();
                const count = self.program.componentCount(typ);
                const length = base.parts.len / count;
                if (self.module.values.items[subscript.parts[0]].instruction == .constant) {
                    const selected = self.module.values.items[subscript.parts[0]].instruction.constant;
                    if (selected >= length) return self.fail(index.line, "constant index is out of bounds", .{});
                    break :value .{ .typ = typ, .parts = base.parts[selected * count ..][0..count] };
                }
                const parts = try self.allocator.alloc(ir.ValueId, count);
                for (parts, 0..) |*part, component| {
                    part.* = base.parts[component];
                    for (0..length) |selected| {
                        const selected_condition = try self.module.compare(.eq, subscript.parts[0], try self.integer(.i32, @intCast(selected)));
                        part.* = try self.module.add(self.module.values.items[base.parts[component]].typ, .{ .select = .{ .condition = selected_condition, .yes = base.parts[selected * count + component], .no = part.* } });
                    }
                }
                break :value .{ .typ = typ, .parts = parts };
            },
            .call => |call_node| self.call(call_node),
            .unary => |unary| value: {
                const operand = try self.expression(unary.operand);
                if (unary.op == .plus) {
                    if (!operand.typ.numeric()) return self.fail(unary.line, "unary + requires a number", .{});
                    break :value operand;
                }
                const parts = try self.allocator.alloc(ir.ValueId, operand.parts.len);
                for (operand.parts, parts) |part, *result| result.* = switch (unary.op) {
                    .minus => if (operand.typ.scalar == .float) try self.negate(part) else if (operand.typ.numeric()) try self.module.binary(.sub, try self.integer(.i32, 0), part) else return self.fail(unary.line, "unary - requires a number", .{}),
                    .logical_not => if (operand.typ.scalar == .bool_ and operand.typ.count() == 1) try self.module.binary(.xor_, part, try self.integer(.i1, 1)) else return self.fail(unary.line, "! requires a bool scalar", .{}),
                    .bit_not => if (operand.typ.scalar == .int or operand.typ.scalar == .uint) try self.module.binary(.xor_, part, try self.integer(.i32, 0xffffffff)) else return self.fail(unary.line, "~ requires an integer", .{}),
                    else => unreachable,
                };
                break :value .{ .typ = operand.typ, .parts = parts };
            },
            .postfix => |postfix| value: {
                const target = try self.lvalue(postfix.operand);
                const previous = try self.readLValue(target);
                const one = try self.single(.{ .scalar = .int }, try self.integer(.i32, 1));
                try self.assign(target, try self.arithmetic(if (postfix.increment) .add else .subtract, previous, one, postfix.line), postfix.line);
                break :value previous;
            },
            .binary => |binary| if (binary.op == .logical_and or binary.op == .logical_or) self.shortCircuit(binary) else self.arithmetic(binary.op, try self.expression(binary.left), try self.expression(binary.right), binary.line),
            .assign => |assignment| value: {
                const target = try self.lvalue(assignment.target);
                var result = try self.expression(assignment.value);
                if (assignment.op != .assign) result = try self.arithmetic(switch (assignment.op) {
                    .assign => unreachable,
                    .add => .add,
                    .subtract => .subtract,
                    .multiply => .multiply,
                    .divide => .divide,
                    .remainder => .remainder,
                    .bit_and => .bit_and,
                    .bit_or => .bit_or,
                    .bit_xor => .bit_xor,
                    .shift_left => .shift_left,
                    .shift_right => .shift_right,
                }, try self.readLValue(target), result, assignment.line);
                result = try self.convert(result, target.typ, false, assignment.line);
                try self.assign(target, result, assignment.line);
                break :value result;
            },
            .ternary => |ternary_node| self.ternary(ternary_node),
            .comma => |comma| value: {
                _ = try self.expression(comma.left);
                break :value self.expression(comma.right);
            },
        };
    }

    fn single(self: *Lowerer, typ: sema.Type, part: ir.ValueId) Error!Value {
        return .{ .typ = typ, .parts = try self.allocator.dupe(ir.ValueId, &.{part}) };
    }

    fn negate(self: *Lowerer, part: ir.ValueId) Error!ir.ValueId {
        const value = self.module.values.items[part];
        if (value.instruction == .constant) return self.integer(.f32, value.instruction.constant ^ 0x80000000);
        const bits = try self.module.add(.i32, .{ .cast = .{ .op = .bitcast, .value = part } });
        return self.module.add(.f32, .{ .cast = .{ .op = .bitcast, .value = try self.module.binary(.xor_, bits, try self.integer(.i32, 0x80000000)) } });
    }

    fn convert(self: *Lowerer, value: Value, target: sema.Type, explicit: bool, line: u32) Error!Value {
        if (self.program.equivalent(value.typ, target)) return .{ .typ = target, .parts = value.parts };
        if (value.typ.rows != target.rows or value.typ.cols != target.cols or value.typ.array_len != target.array_len or value.typ.scalar == .structure or target.scalar == .structure or value.typ.scalar == .sampler or target.scalar == .sampler) return self.fail(line, "incompatible value shape", .{});
        if (!explicit and !(target.scalar == .float and (value.typ.scalar == .int or value.typ.scalar == .uint))) return self.fail(line, "implicit conversion is not permitted", .{});
        const parts = try self.allocator.alloc(ir.ValueId, value.parts.len);
        for (value.parts, parts) |part, *converted| {
            if (target.scalar == .bool_) {
                converted.* = try self.module.compare(if (value.typ.scalar == .float) .une else .ne, part, try self.integer(value.typ.irType(), 0));
            } else if (value.typ.scalar == .bool_) {
                converted.* = try self.module.add(target.irType(), .{ .select = .{ .condition = part, .yes = if (target.scalar == .float) try self.module.float(1) else try self.integer(.i32, 1), .no = try self.integer(target.irType(), 0) } });
            } else if (value.typ.irType() == target.irType()) {
                converted.* = part;
            } else {
                const op: ir.CastOp = if (value.typ.scalar == .float) (if (target.scalar == .uint) .fptoui else .fptosi) else if (value.typ.scalar == .uint) .uitofp else .sitofp;
                if (self.module.values.items[part].instruction == .constant) {
                    const bits = self.module.values.items[part].instruction.constant;
                    if (target.scalar == .float) {
                        converted.* = try self.module.float(if (value.typ.scalar == .uint) @floatFromInt(bits) else @floatFromInt(@as(i32, @bitCast(bits))));
                        continue;
                    }
                }
                converted.* = try self.module.add(target.irType(), .{ .cast = .{ .op = op, .value = part } });
            }
        }
        return .{ .typ = target, .parts = parts };
    }

    fn swizzle(self: *Lowerer, typ: sema.Type, name: []const u8, line: u32) Error![]const u32 {
        if (typ.cols != 1 or typ.array_len != 0 or typ.scalar == .structure or name.len < 1 or name.len > 4) return self.fail(line, "invalid swizzle", .{});
        const parts = try self.allocator.alloc(u32, name.len);
        const sets = [_][]const u8{ "xyzw", "rgba", "stpq" };
        var selected: ?usize = null;
        for (name, parts) |letter, *part| {
            var found = false;
            for (sets, 0..) |set, index| if (std.mem.indexOfScalar(u8, set, letter)) |component| {
                if (selected != null and selected.? != index) return self.fail(line, "swizzle alphabets cannot be mixed", .{});
                if (component >= typ.rows) return self.fail(line, "swizzle component is out of bounds", .{});
                selected = index;
                part.* = @intCast(component);
                found = true;
                break;
            };
            if (!found) return self.fail(line, "invalid swizzle component", .{});
        }
        return parts;
    }

    fn uniform(self: *Lowerer, typ: sema.Type, offset: u32) Error!Value {
        var parts: std.ArrayList(ir.ValueId) = .empty;
        try self.uniformParts(typ, offset, &parts);
        return .{ .typ = typ, .parts = parts.items };
    }

    fn uniformParts(self: *Lowerer, typ: sema.Type, offset: u32, parts: *std.ArrayList(ir.ValueId)) Error!void {
        if (typ.array_len != 0) {
            const stride = self.program.layoutOf(typ).array_stride;
            for (0..typ.array_len) |index| try self.uniformParts(typ.element(), offset + @as(u32, @intCast(index)) * stride, parts);
        } else if (typ.scalar == .structure) {
            for (self.program.structures.items[typ.structure].fields) |field| try self.uniformParts(field.typ, offset + field.offset, parts);
        } else {
            for (0..typ.cols) |column| for (0..typ.rows) |row| {
                const component_offset = offset + @as(u32, @intCast(if (typ.cols > 1) column * 16 + row * 4 else row * 4));
                try parts.append(self.allocator, try self.bufferScalar("Globals", component_offset, typ.scalar));
            };
        }
    }

    fn builtin(self: *Lowerer, name: []const u8, line: u32) Error!Value {
        const vertex = self.stage_index == 0;
        if (!vertex and (std.mem.eql(u8, name, "gl_FragColor") or std.mem.eql(u8, name, "gl_FragDepth"))) {
            const depth = std.mem.eql(u8, name, "gl_FragDepth");
            _ = try self.builtinOutput(if (depth) .depth else .target);
            const variable_index = try self.variable(name, .{ .rows = if (depth) 1 else 4 }, false, true);
            return self.read(variable_index);
        }
        const semantic: ir.Semantic = if (vertex and std.mem.eql(u8, name, "gl_VertexID")) .vertex_id else if (vertex and std.mem.eql(u8, name, "gl_InstanceID")) .instance_id else if (!vertex and std.mem.eql(u8, name, "gl_FragCoord")) .position else if (!vertex and std.mem.eql(u8, name, "gl_FrontFacing")) .front_face else return self.fail(line, "unsupported or wrong-stage built-in '{s}'", .{name});
        var signature_index: ?u32 = null;
        for (self.module.inputs.items, 0..) |input, index| if (input.semantic == semantic) {
            signature_index = @intCast(index);
            break;
        };
        if (signature_index == null) {
            signature_index = @intCast(self.module.inputs.items.len);
            var row: u32 = 0;
            if (semantic != .position) for (self.module.inputs.items) |input| {
                row = @max(row, input.row + 1);
            };
            if (row >= 32) return self.fail(line, "built-in input exceeds 32 signature rows", .{});
            try self.module.inputs.append(self.allocator, .{
                .name = switch (semantic) {
                    .vertex_id => "SV_VertexID",
                    .instance_id => "SV_InstanceID",
                    .position => "SV_Position",
                    .front_face => "SV_IsFrontFace",
                    else => unreachable,
                },
                .row = row,
                .semantic = semantic,
                .columns = if (semantic == .position) 4 else 1,
                .scalar = if (semantic == .position) .float else .uint,
                .interpolation = if (vertex) 0 else if (semantic == .position) 4 else 1,
            });
        }
        var value = try self.loadInput(signature_index.?, .{ .scalar = if (semantic == .position) .float else .int, .rows = if (semantic == .position) 4 else 1 });
        if (semantic == .front_face) return self.single(.{ .scalar = .bool_ }, try self.module.compare(.ne, value.parts[0], try self.integer(.i32, 0)));
        if (self.program.opengl) {
            if (semantic == .position) {
                const parts = try self.allocator.dupe(ir.ValueId, value.parts);
                parts[1] = try self.module.binary(.sub, try self.compatFloat(3), parts[1]);
                parts[3] = try self.module.binary(.fdiv, try self.module.float(1), parts[3]);
                value.parts = parts;
            }
            if (semantic == .instance_id) value = try self.single(value.typ, try self.module.binary(.sub, value.parts[0], try self.bufferScalar("GlCompat", 16, .uint)));
        }
        return value;
    }

    fn lvalue(self: *Lowerer, expression_node: *ast.Expr) Error!LValue {
        if (self.expression_depth >= 256) return self.fail(expression_node.line(), "lvalue exceeds nesting resource limit", .{});
        self.expression_depth += 1;
        defer self.expression_depth -= 1;
        return switch (expression_node.*) {
            .identifier => |identifier| value: {
                try self.markBuiltinOutput(identifier.name, identifier.line);
                if (self.findVariable(identifier.name) == null and std.mem.startsWith(u8, identifier.name, "gl_")) {
                    _ = try self.builtin(identifier.name, identifier.line);
                }
                const variable_index = self.findVariable(identifier.name) orelse return self.fail(identifier.line, "assignment target is not writable", .{});
                const variable_value = self.variables.items[variable_index];
                if (variable_value.readonly) return self.fail(identifier.line, "assignment to read-only variable", .{});
                const indices = try self.allocator.alloc(u32, self.program.componentCount(variable_value.typ));
                for (indices, 0..) |*index, component| index.* = @intCast(component);
                break :value .{ .variable = variable_index, .typ = variable_value.typ, .indices = indices };
            },
            .member => |member| value: {
                const base = try self.lvalue(member.base);
                if (base.typ.scalar == .structure) {
                    var offset: usize = 0;
                    for (self.program.structures.items[base.typ.structure].fields) |field| {
                        const count = self.program.componentCount(field.typ);
                        if (std.mem.eql(u8, field.name, member.name)) break :value .{ .variable = base.variable, .typ = field.typ, .indices = base.indices[offset .. offset + count] };
                        offset += count;
                    }
                    return self.fail(member.line, "unknown structure field", .{});
                }
                const components = try self.swizzle(base.typ, member.name, member.line);
                const indices = try self.allocator.alloc(u32, components.len);
                for (components, indices, 0..) |component, *index, position| {
                    for (components[0..position]) |previous| if (previous == component) return self.fail(member.line, "writable swizzles cannot repeat components", .{});
                    index.* = base.indices[component];
                }
                break :value .{ .variable = base.variable, .typ = .{ .scalar = base.typ.scalar, .rows = @intCast(indices.len) }, .indices = indices };
            },
            .index => |index| value: {
                const base = try self.lvalue(index.base);
                if (base.typ.array_len == 0 and base.typ.cols == 1 and base.typ.rows == 1) return self.fail(index.line, "indexing requires an aggregate", .{});
                const subscript = try self.expression(index.index);
                if (subscript.parts.len != 1 or (subscript.typ.scalar != .int and subscript.typ.scalar != .uint) or self.module.values.items[subscript.parts[0]].instruction != .constant) return self.fail(index.line, "dynamic indexing of writable local objects is not supported", .{});
                const selected = self.module.values.items[subscript.parts[0]].instruction.constant;
                const typ = base.typ.element();
                const count = self.program.componentCount(typ);
                if (selected >= base.indices.len / count) return self.fail(index.line, "constant index is out of bounds", .{});
                break :value .{ .variable = base.variable, .typ = typ, .indices = base.indices[selected * count ..][0..count] };
            },
            else => self.fail(expression_node.line(), "expression is not an assignment target", .{}),
        };
    }

    fn readLValue(self: *Lowerer, target: LValue) Error!Value {
        const base = try self.read(target.variable);
        const parts = try self.allocator.alloc(ir.ValueId, target.indices.len);
        for (target.indices, parts) |index, *part| part.* = base.parts[index];
        return .{ .typ = target.typ, .parts = parts };
    }

    fn markBuiltinOutput(self: *Lowerer, name: []const u8, line: u32) Error!void {
        if (std.mem.eql(u8, name, "gl_FragColor")) {
            if (self.stage_index != 1) return self.fail(line, "gl_FragColor requires a fragment shader", .{});
            for (self.program.stages[1].globals.items) |global| if (global.kind == .output and global.location == 0) return self.fail(line, "gl_FragColor conflicts with fragment output location 0", .{});
            self.uses_frag_color = true;
            _ = try self.builtinOutput(.target);
        }
        if (std.mem.eql(u8, name, "gl_FragDepth")) {
            if (self.stage_index != 1) return self.fail(line, "gl_FragDepth requires a fragment shader", .{});
            self.uses_frag_depth = true;
            _ = try self.builtinOutput(.depth);
        }
    }

    fn assign(self: *Lowerer, target: LValue, value: Value, line: u32) Error!void {
        const converted = try self.convert(value, target.typ, false, line);
        const base = try self.read(target.variable);
        const parts = try self.allocator.dupe(ir.ValueId, base.parts);
        for (target.indices, converted.parts) |index, part| parts[index] = part;
        try self.write(target.variable, .{ .typ = base.typ, .parts = parts });
    }

    fn arithmetic(self: *Lowerer, op: ast.BinaryOp, left: Value, right: Value, line: u32) Error!Value {
        if (op == .logical_xor) {
            if (left.typ.scalar != .bool_ or right.typ.scalar != .bool_ or left.parts.len != 1 or right.parts.len != 1) return self.fail(line, "logical operands must be bool scalars", .{});
            return self.single(.{ .scalar = .bool_ }, try self.module.binary(.xor_, left.parts[0], right.parts[0]));
        }
        const equality = op == .equal or op == .not_equal;
        if (equality and (left.typ.rows != right.typ.rows or left.typ.cols != right.typ.cols or left.typ.array_len != right.typ.array_len)) return self.fail(line, "equality requires matching shapes", .{});
        if (!left.typ.numeric() or !right.typ.numeric()) {
            if (equality and left.typ.scalar == .bool_ and self.program.equivalent(left.typ, right.typ)) {
                var result = try self.integer(.i1, if (op == .equal) 1 else 0);
                for (left.parts, right.parts) |left_part, right_part| result = try self.module.binary(if (op == .equal) .and_ else .or_, result, try self.module.compare(if (op == .equal) .eq else .ne, left_part, right_part));
                return self.single(.{ .scalar = .bool_ }, result);
            }
            return self.fail(line, "operator requires numeric operands", .{});
        }
        if (op == .multiply and ((left.typ.cols > 1 and right.typ.partsShapeVector()) or (right.typ.cols > 1 and left.typ.partsShapeVector()) or (left.typ.cols > 1 and right.typ.cols > 1))) return self.matrixMultiply(left, right, line);
        if (left.typ.array_len != 0 or right.typ.array_len != 0) return self.fail(line, "array arithmetic is not supported", .{});
        var target = if (left.parts.len >= right.parts.len) left.typ else right.typ;
        if (left.parts.len != right.parts.len and left.parts.len != 1 and right.parts.len != 1) return self.fail(line, "incompatible operand shapes", .{});
        if (left.parts.len > 1 and right.parts.len > 1 and (left.typ.rows != right.typ.rows or left.typ.cols != right.typ.cols)) return self.fail(line, "incompatible operand shapes", .{});
        target.scalar = if (left.typ.scalar == .float or right.typ.scalar == .float) .float else if (left.typ.scalar == .uint or right.typ.scalar == .uint) .uint else .int;
        var left_type = left.typ;
        left_type.scalar = target.scalar;
        var right_type = right.typ;
        right_type.scalar = target.scalar;
        const left_value = try self.convert(left, left_type, true, line);
        const right_value = try self.convert(right, right_type, true, line);
        const comparison = equality or op == .less or op == .greater or op == .less_equal or op == .greater_equal;
        if (comparison and !equality and target.count() != 1) return self.fail(line, "relational operators require scalar operands", .{});
        const parts = try self.allocator.alloc(ir.ValueId, target.count());
        for (parts, 0..) |*part, component| {
            const left_part = left_value.parts[if (left_value.parts.len == 1) 0 else component];
            const right_part = right_value.parts[if (right_value.parts.len == 1) 0 else component];
            if (comparison) {
                const predicate: ir.Predicate = if (target.scalar == .float) switch (op) {
                    .equal => .oeq,
                    .not_equal => .une,
                    .less => .olt,
                    .greater => .ogt,
                    .less_equal => .ole,
                    .greater_equal => .oge,
                    else => unreachable,
                } else switch (op) {
                    .equal => .eq,
                    .not_equal => .ne,
                    .less => if (target.scalar == .uint) .ult else .slt,
                    .greater => if (target.scalar == .uint) .ugt else .sgt,
                    .less_equal => if (target.scalar == .uint) .ule else .sle,
                    .greater_equal => if (target.scalar == .uint) .uge else .sge,
                    else => unreachable,
                };
                part.* = try self.module.compare(predicate, left_part, right_part);
            } else {
                const operation: ir.BinaryOp = switch (op) {
                    .add => .add,
                    .subtract => .sub,
                    .multiply => .mul,
                    .divide => if (target.scalar == .float) .fdiv else if (target.scalar == .uint) .udiv else .sdiv,
                    .remainder => if (target.scalar == .float) return self.fail(line, "% requires integer operands", .{}) else if (target.scalar == .uint) .urem else .srem,
                    .bit_and => .and_,
                    .bit_or => .or_,
                    .bit_xor => .xor_,
                    .shift_left => .shl,
                    .shift_right => if (target.scalar == .uint) .lshr else .ashr,
                    else => return self.fail(line, "unsupported operator", .{}),
                };
                if (target.scalar == .float and (operation == .and_ or operation == .or_ or operation == .xor_ or operation == .shl or operation == .lshr or operation == .ashr)) return self.fail(line, "bitwise operators require integers", .{});
                part.* = try self.module.binary(operation, left_part, right_part);
            }
        }
        if (comparison) {
            var result = parts[0];
            for (parts[1..]) |part| result = try self.module.binary(if (op == .not_equal) .or_ else .and_, result, part);
            return self.single(.{ .scalar = .bool_ }, result);
        }
        return .{ .typ = target, .parts = parts };
    }

    fn matrixMultiply(self: *Lowerer, left: Value, right: Value, line: u32) Error!Value {
        if (left.typ.scalar != .float or right.typ.scalar != .float) return self.fail(line, "matrix multiplication requires float operands", .{});
        const left_matrix = left.typ.cols > 1;
        const right_matrix = right.typ.cols > 1;
        const inner: usize = if (left_matrix) left.typ.cols else left.typ.rows;
        if (inner != right.typ.rows) return self.fail(line, "matrix dimensions do not match", .{});
        const rows: u8 = if (left_matrix) left.typ.rows else 1;
        const cols: u8 = if (right_matrix) right.typ.cols else 1;
        const typ: sema.Type = if (left_matrix and right_matrix) .{ .rows = rows, .cols = cols } else .{ .rows = if (left_matrix) rows else cols };
        const parts = try self.allocator.alloc(ir.ValueId, typ.count());
        for (0..cols) |column| for (0..rows) |row| {
            var sum = try self.module.float(0);
            for (0..inner) |component| {
                const left_part = left.parts[if (left_matrix) component * left.typ.rows + row else component];
                const right_part = right.parts[if (right_matrix) column * right.typ.rows + component else component];
                sum = try self.module.binary(.add, sum, try self.module.binary(.mul, left_part, right_part));
            }
            parts[column * rows + row] = sum;
        };
        return .{ .typ = typ, .parts = parts };
    }

    fn condition(self: *Lowerer, value: Value, line: u32) Error!ir.ValueId {
        if (value.typ.scalar != .bool_ or value.parts.len != 1) return self.fail(line, "condition must be a bool scalar", .{});
        return value.parts[0];
    }

    fn shortCircuit(self: *Lowerer, binary: ast.Binary) Error!Value {
        const condition_value = try self.condition(try self.expression(binary.left), binary.line);
        const predecessor = self.module.current;
        const rhs = try self.newBlock();
        const merge = try self.newBlock();
        if (binary.op == .logical_and) try self.conditional(condition_value, rhs, merge) else try self.conditional(condition_value, merge, rhs);
        try self.seal(rhs);
        self.module.current = rhs;
        const right = try self.condition(try self.expression(binary.right), binary.line);
        const right_predecessor = self.module.current;
        try self.branch(merge);
        try self.seal(merge);
        self.module.current = merge;
        return self.single(.{ .scalar = .bool_ }, try self.module.phi(.i1, &.{ .{ .value = try self.integer(.i1, if (binary.op == .logical_or) 1 else 0), .block = predecessor }, .{ .value = right, .block = right_predecessor } }));
    }

    fn ternary(self: *Lowerer, ternary_node: ast.Ternary) Error!Value {
        const condition_value = try self.condition(try self.expression(ternary_node.condition), ternary_node.line);
        const yes = try self.newBlock();
        const no = try self.newBlock();
        const merge = try self.newBlock();
        try self.conditional(condition_value, yes, no);
        try self.seal(yes);
        try self.seal(no);
        self.module.current = yes;
        const yes_value = try self.expression(ternary_node.then_expr);
        const yes_predecessor = self.module.current;
        try self.branch(merge);
        self.module.current = no;
        const no_value = try self.expression(ternary_node.else_expr);
        if (!self.program.equivalent(yes_value.typ, no_value.typ)) return self.fail(ternary_node.line, "conditional branches require matching types", .{});
        const no_predecessor = self.module.current;
        try self.branch(merge);
        try self.seal(merge);
        self.module.current = merge;
        const parts = try self.allocator.alloc(ir.ValueId, yes_value.parts.len);
        for (parts, yes_value.parts, no_value.parts) |*part, yes_part, no_part| part.* = try self.module.phi(self.module.values.items[yes_part].typ, &.{ .{ .value = yes_part, .block = yes_predecessor }, .{ .value = no_part, .block = no_predecessor } });
        return .{ .typ = yes_value.typ, .parts = parts };
    }

    fn call(self: *Lowerer, call_node: ast.Call) Error!Value {
        var constructor = @import("../glsl/types.zig").fromBuiltinName(call_node.callee) != null;
        for (self.program.structures.items) |structure| if (@backingInt(structure.stage) == self.stage_index and std.mem.eql(u8, structure.decl.name, call_node.callee)) {
            constructor = true;
        };
        if (constructor) return self.construct(try self.program.resolveType(self.stage_index, .{ .name = call_node.callee, .line = call_node.line, .column = call_node.column }), call_node);
        if (std.mem.eql(u8, call_node.callee, "texture") or std.mem.eql(u8, call_node.callee, "texture2D") or std.mem.eql(u8, call_node.callee, "textureLod") or std.mem.eql(u8, call_node.callee, "texelFetch")) return self.texture(call_node);
        for (self.program.stages[self.stage_index].unit.decls) |declaration| if (declaration.* == .function and declaration.function.body != null and std.mem.eql(u8, declaration.function.name, call_node.callee)) return self.userCall(call_node);
        if (call_node.args.len == 0 or call_node.args.len > 3) return self.fail(call_node.line, "unsupported built-in '{s}'", .{call_node.callee});
        const args = try self.allocator.alloc(Value, call_node.args.len);
        for (call_node.args, args) |argument, *value| value.* = try self.expression(argument);
        const name = call_node.callee;
        if (std.mem.eql(u8, name, "dot") or std.mem.eql(u8, name, "normalize") or std.mem.eql(u8, name, "length")) {
            const dot = std.mem.eql(u8, name, "dot");
            if (args.len != (if (dot) @as(usize, 2) else 1) or args[0].typ.scalar != .float or args[0].typ.cols != 1 or args[0].typ.array_len != 0) return self.fail(call_node.line, "invalid geometric built-in arguments", .{});
            if (dot and !self.program.equivalent(args[0].typ, args[1].typ)) return self.fail(call_node.line, "dot arguments must match", .{});
            var sum = try self.module.float(0);
            for (args[0].parts, if (dot) args[1].parts else args[0].parts) |left, right| sum = try self.module.binary(.add, sum, try self.module.binary(.mul, left, right));
            if (dot) return self.single(.{}, sum);
            const result = try self.module.call(.unary, &.{ try self.integer(.i32, if (std.mem.eql(u8, name, "normalize")) 25 else 24), sum });
            if (std.mem.eql(u8, name, "length")) return self.single(.{}, result);
            const parts = try self.allocator.alloc(ir.ValueId, args[0].parts.len);
            for (args[0].parts, parts) |part, *output| output.* = try self.module.binary(.mul, part, result);
            return .{ .typ = args[0].typ, .parts = parts };
        }
        if (std.mem.eql(u8, name, "mix")) {
            if (args.len != 3 or !self.program.equivalent(args[0].typ, args[1].typ) or args[0].typ.scalar != .float or args[2].typ.scalar != .float or (args[2].parts.len != 1 and args[2].parts.len != args[0].parts.len)) return self.fail(call_node.line, "invalid mix arguments", .{});
            const parts = try self.allocator.alloc(ir.ValueId, args[0].parts.len);
            for (parts, 0..) |*part, index| {
                const factor = args[2].parts[if (args[2].parts.len == 1) 0 else index];
                part.* = try self.module.binary(.add, try self.module.binary(.mul, args[0].parts[index], try self.module.binary(.sub, try self.module.float(1), factor)), try self.module.binary(.mul, args[1].parts[index], factor));
            }
            return .{ .typ = args[0].typ, .parts = parts };
        }
        if (std.mem.eql(u8, name, "max") or std.mem.eql(u8, name, "min")) {
            if (args.len != 2 or args[0].typ.scalar != .float or args[1].typ.scalar != .float or (args[1].parts.len != args[0].parts.len and args[1].parts.len != 1)) return self.fail(call_node.line, "min/max require compatible float arguments", .{});
            const parts = try self.allocator.alloc(ir.ValueId, args[0].parts.len);
            for (parts, args[0].parts, 0..) |*part, left, index| part.* = try self.module.call(.binary, &.{ try self.integer(.i32, if (std.mem.eql(u8, name, "max")) 35 else 36), left, args[1].parts[if (args[1].parts.len == 1) 0 else index] });
            return .{ .typ = args[0].typ, .parts = parts };
        }
        const unary_names = [_][]const u8{ "abs", "sin", "cos", "sqrt", "inversesqrt", "floor", "ceil", "trunc", "fract" };
        const opcodes = [_]u32{ 6, 13, 12, 24, 25, 27, 28, 29, 22 };
        for (unary_names, opcodes) |candidate, opcode| if (std.mem.eql(u8, candidate, name)) {
            if (args.len != 1 or args[0].typ.scalar != .float or args[0].typ.cols != 1 or args[0].typ.array_len != 0) return self.fail(call_node.line, "unary built-in requires float scalar or vector", .{});
            const parts = try self.allocator.alloc(ir.ValueId, args[0].parts.len);
            for (parts, args[0].parts) |*part, source| part.* = try self.module.call(.unary, &.{ try self.integer(.i32, opcode), source });
            return .{ .typ = args[0].typ, .parts = parts };
        };
        return self.fail(call_node.line, "unsupported built-in '{s}'", .{name});
    }

    fn construct(self: *Lowerer, typ: sema.Type, call_node: ast.Call) Error!Value {
        if (typ.scalar == .void_ or typ.scalar == .sampler or call_node.args.len == 0) return self.fail(call_node.line, "invalid constructor", .{});
        const args = try self.allocator.alloc(Value, call_node.args.len);
        for (args, call_node.args) |*value, expression_node| value.* = try self.expression(expression_node);
        if (typ.scalar == .structure) {
            const fields = self.program.structures.items[typ.structure].fields;
            if (fields.len != args.len) return self.fail(call_node.line, "structure constructor arity does not match", .{});
            var parts: std.ArrayList(ir.ValueId) = .empty;
            for (args, fields) |argument, field| try parts.appendSlice(self.allocator, (try self.convert(argument, field.typ, false, call_node.line)).parts);
            return .{ .typ = typ, .parts = parts.items };
        }
        if (typ.count() == 1) {
            if (args.len != 1 or args[0].typ.scalar == .structure) return self.fail(call_node.line, "scalar constructor expects one scalar or vector", .{});
            return self.convert(.{ .typ = args[0].typ.scalarType(), .parts = args[0].parts[0..1] }, typ, true, call_node.line);
        }
        const parts = try self.allocator.alloc(ir.ValueId, typ.count());
        if (args.len == 1 and args[0].parts.len == 1) {
            const scalar = (try self.convert(args[0], typ.scalarType(), true, call_node.line)).parts[0];
            for (parts, 0..) |*part, index| part.* = if (typ.cols == 1 or index / typ.rows == index % typ.rows) scalar else try self.module.float(0);
            return .{ .typ = typ, .parts = parts };
        }
        var count: usize = 0;
        for (args) |argument| {
            var target = argument.typ;
            target.scalar = typ.scalar;
            const converted = try self.convert(argument, target, true, call_node.line);
            if (count + converted.parts.len > parts.len) return self.fail(call_node.line, "too many constructor components", .{});
            @memcpy(parts[count .. count + converted.parts.len], converted.parts);
            count += converted.parts.len;
        }
        if (count != parts.len) return self.fail(call_node.line, "constructor component count does not match", .{});
        return .{ .typ = typ, .parts = parts };
    }

    fn texture(self: *Lowerer, call_node: ast.Call) Error!Value {
        const implicit = std.mem.eql(u8, call_node.callee, "texture") or std.mem.eql(u8, call_node.callee, "texture2D");
        const fetch = std.mem.eql(u8, call_node.callee, "texelFetch");
        if (call_node.args.len != (if (implicit) @as(usize, 2) else 3) or call_node.args[0].* != .identifier) return self.fail(call_node.line, "invalid texture arguments", .{});
        if (implicit and self.stage_index != 1) return self.fail(call_node.line, "implicit LOD sampling requires a fragment shader", .{});
        const name = call_node.args[0].identifier.name;
        const global = self.findGlobal(name) orelse return self.fail(call_node.line, "sampling requires a sampler uniform", .{});
        if (global.kind != .uniform or global.typ.scalar != .sampler) return self.fail(call_node.line, "sampling requires a sampler uniform", .{});
        const coordinates = try self.expression(call_node.args[1]);
        if (coordinates.parts.len != 2 or coordinates.typ.scalar != (if (fetch) sema.Scalar.int else .float)) return self.fail(call_node.line, "invalid texture coordinates", .{});
        var texture_handle: ?ir.ValueId = null;
        var sampler_handle: ?ir.ValueId = null;
        for (self.module.resources.items, self.handles.items) |resource, handle| if (std.mem.eql(u8, resource.name, name)) {
            if (resource.class == .srv) texture_handle = handle;
            if (resource.class == .sampler) sampler_handle = handle;
        };
        const level = if (implicit) null else try self.expression(call_node.args[2]);
        if (level) |lod| if (lod.parts.len != 1 or lod.typ.scalar != (if (fetch) sema.Scalar.int else .float)) return self.fail(call_node.line, "invalid texture level", .{});
        const zero = try self.integer(.i32, 0);
        const aggregate = if (fetch) try self.module.intrinsic(.texture_load, &.{ texture_handle.?, level.?.parts[0], coordinates.parts[0], coordinates.parts[1], try self.module.undef(.i32), zero, zero, try self.module.undef(.i32) }) else try self.module.intrinsic(if (implicit) .sample else .sample_level, &.{ texture_handle.?, sampler_handle.?, coordinates.parts[0], coordinates.parts[1], try self.module.undef(.f32), try self.module.undef(.f32), zero, zero, try self.module.undef(.i32), if (implicit) try self.module.undef(.f32) else level.?.parts[0] });
        const parts = try self.allocator.alloc(ir.ValueId, 4);
        for (parts, 0..) |*part, index| part.* = try self.module.add(.f32, .{ .extract = .{ .value = aggregate, .index = @intCast(index) } });
        return .{ .typ = .{ .rows = 4 }, .parts = parts };
    }

    fn userCall(self: *Lowerer, call_node: ast.Call) Error!Value {
        var function: ?*ast.Function = null;
        for (self.program.stages[self.stage_index].unit.decls) |declaration| if (declaration.* == .function and declaration.function.body != null and std.mem.eql(u8, declaration.function.name, call_node.callee)) {
            function = declaration.function;
            break;
        };
        const definition = function orelse return self.fail(call_node.line, "unknown function '{s}'", .{call_node.callee});
        if (definition.params.len != call_node.args.len) return self.fail(call_node.line, "function argument count does not match", .{});
        for (self.calls.items) |active| if (std.mem.eql(u8, active, definition.name)) return self.fail(call_node.line, "recursive functions are not supported", .{});
        if (self.calls.items.len >= 32) return self.fail(call_node.line, "function inline depth exceeds 32", .{});
        const return_type = try self.program.resolveType(self.stage_index, definition.return_type);
        const args = try self.allocator.alloc(?Value, call_node.args.len);
        const targets = try self.allocator.alloc(?LValue, call_node.args.len);
        const parameter_types = try self.allocator.alloc(sema.Type, call_node.args.len);
        for (definition.params, call_node.args, 0..) |parameter, argument, index| {
            var typ = try self.program.resolveType(self.stage_index, parameter.typ);
            if (parameter.array_len) |length| typ.array_len = try self.program.arrayLength(self.stage_index, length);
            if (typ.scalar == .void_ or typ.scalar == .sampler) return self.fail(call_node.line, "unsupported function parameter type", .{});
            parameter_types[index] = typ;
            targets[index] = null;
            if (parameter.direction != .in) {
                targets[index] = try self.lvalue(argument);
                if (!self.program.equivalent(targets[index].?.typ, typ)) return self.fail(call_node.line, "out/inout argument type must match exactly", .{});
                for (targets[0..index]) |earlier| if (earlier) |previous| {
                    if (previous.variable == targets[index].?.variable) for (previous.indices) |previous_index| {
                        if (std.mem.indexOfScalar(u32, targets[index].?.indices, previous_index) != null) return self.fail(call_node.line, "overlapping out/inout arguments are not supported", .{});
                    };
                };
            }
            args[index] = if (parameter.direction == .out) null else if (targets[index]) |target| try self.readLValue(target) else try self.convert(try self.expression(argument), typ, false, call_node.line);
        }
        const previous_frame = self.frame;
        const previous_scope = self.scope_start;
        const previous_break = self.break_target;
        const previous_continue = self.continue_target;
        const variable_count = self.variables.items.len;
        const return_block = try self.newBlock();
        self.frame = .{ .start = variable_count, .return_block = return_block, .return_value = null, .return_type = return_type };
        if (return_type.scalar != .void_) self.frame.?.return_value = try self.variable("$return", return_type, false, false);
        self.break_target = null;
        self.continue_target = null;
        self.scope_start = variable_count;
        try self.calls.append(self.allocator, definition.name);
        const parameters = try self.allocator.alloc(usize, args.len);
        for (definition.params, parameter_types, args, parameters) |parameter, typ, argument, *variable_index| {
            const name = parameter.name orelse return self.fail(definition.line, "function definitions require named parameters", .{});
            for (self.variables.items[variable_count..]) |existing| if (std.mem.eql(u8, existing.name, name)) return self.fail(definition.line, "duplicate parameter", .{});
            variable_index.* = try self.variable(name, typ, parameter.qualifiers.storage == .const_, false);
            if (argument) |value| try self.write(variable_index.*, value);
        }
        if (definition.body.?.* == .block) {
            for (definition.body.?.block.statements) |child| try self.statement(child);
        } else try self.statement(definition.body.?);
        if (!self.terminated()) {
            if (return_type.scalar != .void_) return self.fail(definition.line, "non-void function can fall through without returning", .{});
            try self.branch(return_block);
        }
        if (self.blocks.items[return_block].predecessors.items.len == 0) return self.fail(definition.line, "function requires a reachable return", .{});
        try self.seal(return_block);
        self.module.current = return_block;
        const result = if (self.frame.?.return_value) |variable_index| try self.read(variable_index) else Value{ .typ = return_type, .parts = &.{} };
        const copied = try self.allocator.alloc(?Value, args.len);
        for (targets, parameters, copied) |target, parameter, *value| value.* = if (target != null) try self.read(parameter) else null;
        self.variables.items.len = variable_count;
        self.frame = previous_frame;
        self.scope_start = previous_scope;
        self.break_target = previous_break;
        self.continue_target = previous_continue;
        self.calls.items.len -= 1;
        for (targets, copied) |target, value| if (target) |destination| try self.assign(destination, value.?, call_node.line);
        return result;
    }

    fn statement(self: *Lowerer, node: *ast.Stmt) Error!void {
        const previous_location = self.source_location;
        self.source_location = self.program.stages[self.stage_index].unit.statement_locations.get(node) orelse previous_location;
        defer self.source_location = previous_location;
        const unreachable_statement = self.terminated();
        if (unreachable_statement) {
            if (self.validation_entry == null) return;
            const unreachable_block = try self.newBlock();
            try self.seal(unreachable_block);
            self.module.current = unreachable_block;
        }
        defer if (unreachable_statement and !self.terminated()) {
            self.module.terminate(.ret);
        };
        switch (node.*) {
            .block => |block| {
                const count = self.variables.items.len;
                const previous_scope = self.scope_start;
                self.scope_start = count;
                for (block.statements) |child| try self.statement(child);
                self.variables.items.len = count;
                self.scope_start = previous_scope;
            },
            .expr => |expression_node| {
                _ = try self.expression(expression_node);
            },
            .decl => |declarations| for (declarations) |declaration| {
                for (self.variables.items[self.scope_start..]) |existing| if (std.mem.eql(u8, existing.name, declaration.name)) return self.fail(declaration.line, "duplicate local variable", .{});
                if (declaration.qualifiers.storage != null and declaration.qualifiers.storage != .const_) return self.fail(declaration.line, "unsupported local storage qualifier", .{});
                var typ = try self.program.resolveType(self.stage_index, declaration.typ);
                if (declaration.array_len) |length| typ.array_len = try self.program.arrayLength(self.stage_index, length);
                if (typ.scalar == .void_ or typ.scalar == .sampler) return self.fail(declaration.line, "invalid local type", .{});
                const initializer = if (declaration.initializer) |expression_node| try self.convert(try self.expression(expression_node), typ, false, declaration.line) else null;
                if (declaration.qualifiers.storage == .const_ and initializer == null) return self.fail(declaration.line, "const requires an initializer", .{});
                const variable_index = try self.variable(declaration.name, typ, declaration.qualifiers.storage == .const_, false);
                if (initializer) |value| try self.write(variable_index, value);
            },
            .if_stmt => |if_node| {
                const condition_value = try self.condition(try self.expression(if_node.condition), if_node.line);
                const yes = try self.newBlock();
                const no = try self.newBlock();
                const merge = try self.newBlock();
                try self.conditional(condition_value, yes, no);
                try self.seal(yes);
                try self.seal(no);
                self.module.current = yes;
                try self.statement(if_node.then_branch);
                if (!self.terminated()) try self.branch(merge);
                self.module.current = no;
                if (if_node.else_branch) |otherwise| try self.statement(otherwise);
                if (!self.terminated()) try self.branch(merge);
                try self.seal(merge);
                self.module.current = merge;
                if (self.blocks.items[merge].predecessors.items.len == 0) self.module.terminate(.ret);
            },
            .for_stmt => |loop_node| {
                const count = self.variables.items.len;
                const previous_scope = self.scope_start;
                self.scope_start = count;
                if (loop_node.init) |initializer| try self.statement(initializer);
                try self.loop(loop_node.condition, loop_node.increment, loop_node.body, false, loop_node.line);
                self.variables.items.len = count;
                self.scope_start = previous_scope;
            },
            .while_stmt => |loop_node| try self.loop(loop_node.condition, null, loop_node.body, false, loop_node.line),
            .do_while => |loop_node| try self.loop(loop_node.condition, null, loop_node.body, true, loop_node.line),
            .switch_stmt => |switch_node| try self.switchStatement(switch_node),
            .return_stmt => |return_node| {
                const frame = self.frame orelse return self.fail(return_node.line, "return outside a function", .{});
                if (return_node.value) |expression_node| {
                    if (frame.return_value == null) return self.fail(return_node.line, "void function cannot return a value", .{});
                    try self.write(frame.return_value.?, try self.convert(try self.expression(expression_node), frame.return_type, false, return_node.line));
                } else if (frame.return_value != null) return self.fail(return_node.line, "non-void function requires a return value", .{});
                try self.branch(frame.return_block);
            },
            .break_stmt => try self.branch(self.break_target orelse return self.fail(node.line(), "break outside a loop or switch", .{})),
            .continue_stmt => try self.branch(self.continue_target orelse return self.fail(node.line(), "continue outside a loop", .{})),
            .discard_stmt => {
                if (self.stage_index != 1) return self.fail(node.line(), "discard requires a fragment shader", .{});
                _ = try self.module.intrinsic(.discard, &.{try self.integer(.i1, 1)});
            },
            .case_label, .default_label => return self.fail(node.line(), "case/default outside a switch body", .{}),
        }
    }

    fn loop(self: *Lowerer, condition_node: ?*ast.Expr, increment: ?*ast.Expr, body: *ast.Stmt, do_while: bool, line: u32) Error!void {
        const header = try self.newBlock();
        const loop_body = try self.newBlock();
        const next = try self.newBlock();
        const exit = try self.newBlock();
        const previous_break = self.break_target;
        const previous_continue = self.continue_target;
        self.break_target = exit;
        self.continue_target = next;
        try self.branch(if (do_while) loop_body else header);
        if (!do_while) {
            self.module.current = header;
            const condition_value = if (condition_node) |expression_node| try self.condition(try self.expression(expression_node), line) else try self.integer(.i1, 1);
            try self.conditional(condition_value, loop_body, exit);
            try self.seal(loop_body);
        }
        self.module.current = loop_body;
        try self.statement(body);
        if (!self.terminated()) try self.branch(next);
        try self.seal(next);
        self.module.current = next;
        if (self.blocks.items[next].predecessors.items.len != 0) {
            if (increment) |expression_node| {
                _ = try self.expression(expression_node);
            }
            try self.branch(header);
        } else self.module.terminate(.ret);
        if (do_while) {
            try self.seal(header);
            self.module.current = header;
            if (self.blocks.items[header].predecessors.items.len != 0) {
                const condition_value = try self.condition(try self.expression(condition_node.?), line);
                try self.conditional(condition_value, loop_body, exit);
            } else self.module.terminate(.ret);
            try self.seal(loop_body);
        } else try self.seal(header);
        try self.seal(exit);
        self.module.current = exit;
        if (self.blocks.items[exit].predecessors.items.len == 0) self.module.terminate(.ret);
        self.break_target = previous_break;
        self.continue_target = previous_continue;
    }

    fn switchStatement(self: *Lowerer, switch_node: ast.Switch) Error!void {
        if (switch_node.body.* != .block) return self.fail(switch_node.line, "switch requires a block", .{});
        const selector = try self.expression(switch_node.expression);
        if (selector.parts.len != 1 or (selector.typ.scalar != .int and selector.typ.scalar != .uint)) return self.fail(switch_node.line, "switch requires an integer scalar", .{});
        const statements = switch_node.body.block.statements;
        const Case = struct { start: usize, block: ir.BlockId, value: ?u32 };
        var cases: std.ArrayList(Case) = .empty;
        const exit = try self.newBlock();
        var default_target = exit;
        var has_default = false;
        for (statements, 0..) |child, index| if (child.* == .case_label or child.* == .default_label) {
            const target = try self.newBlock();
            var number: ?u32 = null;
            if (child.* == .default_label) {
                if (has_default) return self.fail(switch_node.line, "duplicate default label", .{});
                has_default = true;
                default_target = target;
            } else {
                const integer_value = self.program.constantInteger(self.stage_index, child.case_label.value, 0) orelse return self.fail(child.line(), "case requires an integer constant", .{});
                if (integer_value < std.math.minInt(i32) or integer_value > std.math.maxInt(u32)) return self.fail(child.line(), "case is outside 32-bit range", .{});
                number = @truncate(@as(u64, @bitCast(integer_value)));
                for (cases.items) |previous| if (previous.value == number) return self.fail(child.line(), "duplicate case label", .{});
            }
            try cases.append(self.allocator, .{ .start = index + 1, .block = target, .value = number });
        };
        if (cases.items.len == 0) return self.fail(switch_node.line, "switch requires a case or default", .{});
        if (cases.items[0].start != 1) return self.fail(switch_node.line, "statements before the first case are not supported", .{});
        for (cases.items) |case| if (case.value) |number| {
            const next = try self.newBlock();
            try self.conditional(try self.module.compare(.eq, selector.parts[0], try self.integer(.i32, number)), case.block, next);
            try self.seal(next);
            self.module.current = next;
        };
        try self.branch(default_target);
        const previous_break = self.break_target;
        self.break_target = exit;
        const variable_count = self.variables.items.len;
        const previous_scope = self.scope_start;
        self.scope_start = variable_count;
        for (cases.items, 0..) |case, index| {
            try self.seal(case.block);
            self.module.current = case.block;
            const end = if (index + 1 < cases.items.len) cases.items[index + 1].start - 1 else statements.len;
            for (statements[case.start..end]) |child| try self.statement(child);
            if (!self.terminated()) try self.branch(if (index + 1 < cases.items.len) cases.items[index + 1].block else exit);
        }
        self.variables.items.len = variable_count;
        self.scope_start = previous_scope;
        try self.seal(exit);
        self.module.current = exit;
        if (self.blocks.items[exit].predecessors.items.len == 0) self.module.terminate(.ret);
        self.break_target = previous_break;
    }

    fn fail(self: *Lowerer, line: u32, comptime format: []const u8, args: anytype) Error {
        const source_line = if (line == 0) self.source_location.line else line;
        return self.program.fail(@max(source_line, 1), if (self.source_location.line == source_line) self.source_location.column else 1, format, args);
    }
};
