const std = @import("std");
const ast = @import("../glsl/ast.zig");
const types = @import("../glsl/types.zig");
const diag = @import("../diag.zig");
const ir = @import("ir.zig");

pub const Error = error{ InvalidShader, OutOfMemory };
pub const Scalar = enum(u32) { void_, bool_, int, uint, float, sampler, structure };
pub const Type = struct {
    scalar: Scalar = .float,
    rows: u8 = 1,
    cols: u8 = 1,
    array_len: u32 = 0,
    structure: u32 = 0,

    pub fn same(self: Type, other: Type) bool {
        return std.meta.eql(self, other);
    }
    pub fn element(self: Type) Type {
        var result = self;
        if (result.array_len != 0) result.array_len = 0 else if (result.cols > 1) result.cols = 1 else result.rows = 1;
        return result;
    }
    pub fn count(self: Type) usize {
        return @as(usize, self.rows) * self.cols * @max(self.array_len, 1);
    }
    pub fn irType(self: Type) ir.Type {
        return switch (self.scalar) {
            .float => .f32,
            .bool_ => .i1,
            .int, .uint => .i32,
            else => .void_,
        };
    }
    pub fn numeric(self: Type) bool {
        return self.scalar == .float or self.scalar == .int or self.scalar == .uint;
    }
    pub fn partsShapeVector(self: Type) bool {
        return self.rows > 1 and self.cols == 1 and self.array_len == 0;
    }
    pub fn scalarType(self: Type) Type {
        return .{ .scalar = self.scalar };
    }
};

pub const Field = struct { name: []const u8, typ: Type, offset: u32 };
pub const Structure = struct { decl: *ast.StructDecl, stage: ir.Stage, fields: []Field = &.{}, size: u32 = 0, resolving: bool = false };
pub const Layout = struct { size: u32, array_stride: u32 = 0, matrix_stride: u32 = 0, aggregate: bool = false };
pub const Global = struct {
    decl: *ast.VarDecl,
    typ: Type,
    kind: enum { input, output, uniform, constant, plain },
    location: ?u32 = null,
    row: u32 = 0,
    signature: ?u32 = null,
    offset: u32 = 0,
    binding: ?u32 = null,
};
pub const Stage = struct { unit: *ast.TranslationUnit, globals: std.ArrayList(Global) = .empty, name: []const u8, mappings: []const diag.Mapping = &.{} };
pub const Uniform = struct { name: []const u8, typ: Type, offset: u32, size: u32, array_stride: u32, matrix_stride: u32, stages: u32 };
pub const Binding = struct { name: []const u8, class: @FieldType(ir.Resource, "class"), binding: u32, space: u32 = 0, size: u32 = 0, stages: u32 };

pub const Program = struct {
    allocator: std.mem.Allocator,
    diagnostics: *diag.Diagnostics,
    stages: [2]Stage,
    structures: std.ArrayList(Structure) = .empty,
    uniforms: std.ArrayList(Uniform) = .empty,
    bindings: std.ArrayList(Binding) = .empty,
    uniform_size: u32 = 0,
    opengl: bool = true,
    structure_depth: u32 = 0,

    pub fn analyze(self: *Program) Error!void {
        for (&self.stages, 0..) |*stage, stage_index| {
            self.context(stage_index);
            for (stage.unit.decls) |declaration| if (declaration.* == .struct_decl) {
                const structure = declaration.struct_decl;
                for (self.structures.items) |existing| if (@backingInt(existing.stage) == stage_index and std.mem.eql(u8, structure.name, existing.decl.name)) return self.fail(structure.line, structure.column, "duplicate structure '{s}'", .{structure.name});
                try self.structures.append(self.allocator, .{ .decl = structure, .stage = @fromBackingInt(@intCast(stage_index)) });
            };
        }
        for (0..self.structures.items.len) |index| try self.resolveStructure(@intCast(index));
        for (&self.stages, 0..) |*stage, stage_index| {
            self.context(stage_index);
            var main_count: usize = 0;
            for (stage.unit.decls, 0..) |declaration, declaration_index| switch (declaration.*) {
                .var_decl => |variable| {
                    if (std.mem.startsWith(u8, variable.name, "gl_")) return self.fail(variable.line, variable.column, "built-in redeclarations are not supported", .{});
                    for (stage.globals.items) |global| if (std.mem.eql(u8, global.decl.name, variable.name)) return self.fail(variable.line, variable.column, "duplicate global '{s}'", .{variable.name});
                    var typ = try self.resolveType(stage_index, variable.typ);
                    if (variable.array_len) |length| typ.array_len = try self.arrayLength(stage_index, length);
                    const kind: @FieldType(Global, "kind") = switch (variable.qualifiers.storage orelse .buffer) {
                        .uniform => .uniform,
                        .const_ => .constant,
                        .in => .input,
                        .out => .output,
                        .attribute => if (stage_index == 0) .input else return self.fail(variable.line, variable.column, "attribute is only available in vertex shaders", .{}),
                        .varying => if (stage_index == 0) .output else .input,
                        .buffer => if (variable.qualifiers.storage == null) .plain else return self.fail(variable.line, variable.column, "buffer storage is not supported", .{}),
                        else => return self.fail(variable.line, variable.column, "unsupported global storage", .{}),
                    };
                    if (typ.scalar == .void_ or (typ.scalar == .sampler and kind != .uniform)) return self.fail(variable.line, variable.column, "invalid global type", .{});
                    if (kind == .uniform and variable.initializer != null) return self.fail(variable.line, variable.column, "uniform initializers are not supported", .{});
                    if ((kind == .input or kind == .output) and (typ.scalar == .structure or typ.scalar == .bool_ or typ.scalar == .sampler or typ.cols != 1 or typ.array_len != 0)) return self.fail(variable.line, variable.column, "stage interfaces require numeric scalars or vectors", .{});
                    const varying = (stage_index == 0 and kind == .output) or (stage_index == 1 and kind == .input);
                    if (varying and typ.scalar != .float and variable.qualifiers.interpolation != .flat) return self.fail(variable.line, variable.column, "integer varyings require flat interpolation", .{});
                    var location: ?u32 = null;
                    var binding: ?u32 = null;
                    for (variable.qualifiers.layout) |qualifier| {
                        const value = qualifier.value orelse return self.fail(variable.line, variable.column, "unsupported layout qualifier '{s}'", .{qualifier.name});
                        if (value < 0 or value > 31) return self.fail(variable.line, variable.column, "layout value must be in 0..31", .{});
                        if (std.mem.eql(u8, qualifier.name, "location")) location = @intCast(value) else if (std.mem.eql(u8, qualifier.name, "binding") and typ.scalar == .sampler) binding = @intCast(value) else return self.fail(variable.line, variable.column, "unsupported layout qualifier '{s}'", .{qualifier.name});
                    }
                    try stage.globals.append(self.allocator, .{ .decl = variable, .typ = typ, .kind = kind, .location = location, .binding = binding });
                },
                .function => |function| {
                    const return_type = try self.resolveType(stage_index, function.return_type);
                    if (return_type.scalar == .sampler) return self.fail(function.line, function.column, "sampler return values are not supported", .{});
                    for (function.params) |parameter| {
                        const typ = try self.resolveType(stage_index, parameter.typ);
                        if (typ.scalar == .void_ or typ.scalar == .sampler) return self.fail(function.line, function.column, "unsupported function parameter type", .{});
                        if (parameter.array_len) |length| _ = try self.arrayLength(stage_index, length);
                    }
                    if (std.mem.eql(u8, function.name, "main") and function.body != null) {
                        main_count += 1;
                        if (function.params.len != 0 or !std.mem.eql(u8, function.return_type.name, "void")) return self.fail(function.line, function.column, "main must be void main()", .{});
                    }
                    for (stage.unit.decls[0..declaration_index]) |previous| if (previous.* == .function and std.mem.eql(u8, previous.function.name, function.name)) {
                        if (previous.function.params.len != function.params.len) return self.fail(function.line, function.column, "function overloading is not supported", .{});
                        if (previous.function.body != null and function.body != null) return self.fail(function.line, function.column, "duplicate function definition", .{});
                        if (!std.mem.eql(u8, previous.function.return_type.name, function.return_type.name)) return self.fail(function.line, function.column, "function return type does not match prototype", .{});
                        for (previous.function.params, function.params) |left, right| if (!std.mem.eql(u8, left.typ.name, right.typ.name) or left.direction != right.direction) return self.fail(function.line, function.column, "function prototype does not match", .{});
                    };
                },
                else => {},
            };
            if (main_count != 1) return self.fail(1, 1, "one main definition is required", .{});
            std.mem.sort(Global, stage.globals.items, {}, lessGlobal);
        }
        try self.link();
        try self.layoutUniforms();
    }

    pub fn context(self: *Program, stage_index: usize) void {
        self.diagnostics.stage = if (stage_index == 0) .vertex else .fragment;
        self.diagnostics.source_name = self.stages[stage_index].name;
        self.diagnostics.mappings = self.stages[stage_index].mappings;
    }

    pub fn resolveType(self: *Program, stage_index: usize, name: ast.TypeName) Error!Type {
        if (types.fromBuiltinName(name.name)) |typ| return switch (typ) {
            .void_ => .{ .scalar = .void_ },
            .scalar => |scalar| .{ .scalar = try self.scalarType(scalar, name) },
            .vector => |vector| .{ .scalar = try self.scalarType(vector.scalar, name), .rows = vector.len },
            .matrix => |matrix| .{ .scalar = .float, .cols = matrix.cols, .rows = matrix.rows },
            .sampler => |sampler| if (sampler == .sampler2D) .{ .scalar = .sampler } else self.fail(name.line, name.column, "only sampler2D is supported", .{}),
            else => self.fail(name.line, name.column, "unsupported type", .{}),
        };
        for (self.structures.items, 0..) |structure, index| if (@backingInt(structure.stage) == stage_index and std.mem.eql(u8, structure.decl.name, name.name)) {
            try self.resolveStructure(@intCast(index));
            return .{ .scalar = .structure, .structure = @intCast(index) };
        };
        return self.fail(name.line, name.column, "unknown type '{s}'", .{name.name});
    }

    fn scalarType(self: *Program, scalar: types.Scalar, name: ast.TypeName) Error!Scalar {
        return switch (scalar) {
            .bool => .bool_,
            .int => .int,
            .uint => .uint,
            .float => .float,
            .double => self.fail(name.line, name.column, "double precision is not supported", .{}),
        };
    }

    fn resolveStructure(self: *Program, index: u32) Error!void {
        const structure = &self.structures.items[index];
        if (structure.resolving) return self.fail(structure.decl.line, structure.decl.column, "recursive structure", .{});
        if (structure.fields.len != 0) return;
        if (self.structure_depth >= 64) return self.fail(structure.decl.line, structure.decl.column, "structure nesting exceeds resource limit", .{});
        self.structure_depth += 1;
        defer self.structure_depth -= 1;
        if (structure.decl.fields.len == 0) return self.fail(structure.decl.line, structure.decl.column, "empty structures are not supported", .{});
        structure.resolving = true;
        structure.fields = try self.allocator.alloc(Field, structure.decl.fields.len);
        var offset: u32 = 0;
        for (structure.decl.fields, 0..) |field, field_index| {
            for (structure.decl.fields[0..field_index]) |earlier| if (std.mem.eql(u8, earlier.name, field.name)) return self.fail(field.line, field.column, "duplicate field", .{});
            var typ = try self.resolveType(@backingInt(structure.stage), field.typ);
            if (field.array_len) |length| typ.array_len = length;
            if (typ.scalar == .void_ or typ.scalar == .sampler) return self.fail(field.line, field.column, "invalid structure field", .{});
            const layout = self.layoutOf(typ);
            offset = place(offset, layout);
            structure.fields[field_index] = .{ .name = field.name, .typ = typ, .offset = offset };
            offset += layout.size;
            if (offset > 65536) return self.fail(field.line, field.column, "structure exceeds 64 KiB resource limit", .{});
        }
        structure.size = align16(offset);
        structure.resolving = false;
    }

    pub fn layoutOf(self: *const Program, typ: Type) Layout {
        if (typ.array_len != 0) {
            const element_layout = self.layoutOf(typ.element());
            const stride = align16(element_layout.size);
            return .{ .size = @min(65552, stride *| typ.array_len), .array_stride = stride, .matrix_stride = element_layout.matrix_stride, .aggregate = true };
        }
        if (typ.scalar == .structure) return .{ .size = self.structures.items[typ.structure].size, .aggregate = true };
        if (typ.cols > 1) return .{ .size = 16 * @as(u32, typ.cols), .matrix_stride = 16, .aggregate = true };
        return .{ .size = 4 * @as(u32, typ.rows) };
    }

    pub fn componentCount(self: *const Program, typ: Type) usize {
        if (typ.array_len != 0) return @min(16385, typ.array_len *| self.componentCount(typ.element()));
        if (typ.scalar != .structure) return typ.count();
        var count: usize = 0;
        for (self.structures.items[typ.structure].fields) |field| count = @min(16385, count + self.componentCount(field.typ));
        return count;
    }

    pub fn equivalent(self: *const Program, left: Type, right: Type) bool {
        if (left.scalar != right.scalar or left.rows != right.rows or left.cols != right.cols or left.array_len != right.array_len) return false;
        if (left.scalar != .structure) return true;
        const left_fields = self.structures.items[left.structure].fields;
        const right_fields = self.structures.items[right.structure].fields;
        if (left_fields.len != right_fields.len) return false;
        for (left_fields, right_fields) |left_field, right_field| if (!std.mem.eql(u8, left_field.name, right_field.name) or !self.equivalent(left_field.typ, right_field.typ)) return false;
        return true;
    }

    pub fn arrayLength(self: *Program, stage_index: usize, expression: *ast.Expr) Error!u32 {
        const location: ast.Location = self.stages[stage_index].unit.expression_locations.get(expression) orelse .{ .line = @max(expression.line(), 1), .column = 1 };
        const number = self.constantInteger(stage_index, expression, 0) orelse return self.fail(location.line, location.column, "array length must be an integer constant", .{});
        if (number <= 0 or number > 4096) return self.fail(location.line, location.column, "array length must be in 1..4096", .{});
        return @intCast(number);
    }

    pub fn constantInteger(self: *Program, stage_index: usize, expression: *ast.Expr, depth: u32) ?i64 {
        if (depth > 64) return null;
        return switch (expression.*) {
            .int_literal => |text| std.fmt.parseInt(i64, text, 0) catch null,
            .uint_literal => |text| std.fmt.parseInt(i64, std.mem.trimEnd(u8, text, "uU"), 0) catch null,
            .unary => |unary| value: {
                const operand = self.constantInteger(stage_index, unary.operand, depth + 1) orelse return null;
                break :value switch (unary.op) {
                    .minus => std.math.sub(i64, 0, operand) catch null,
                    .plus => operand,
                    .bit_not => ~operand,
                    else => null,
                };
            },
            .binary => |binary| value: {
                const left = self.constantInteger(stage_index, binary.left, depth + 1) orelse return null;
                const right = self.constantInteger(stage_index, binary.right, depth + 1) orelse return null;
                break :value switch (binary.op) {
                    .add => std.math.add(i64, left, right) catch null,
                    .subtract => std.math.sub(i64, left, right) catch null,
                    .multiply => std.math.mul(i64, left, right) catch null,
                    .divide => if (right == 0 or (left == std.math.minInt(i64) and right == -1)) null else @divTrunc(left, right),
                    .remainder => if (right == 0 or (left == std.math.minInt(i64) and right == -1)) null else @rem(left, right),
                    .bit_and => left & right,
                    .bit_or => left | right,
                    .bit_xor => left ^ right,
                    else => null,
                };
            },
            .identifier => |identifier| value: {
                for (self.stages[stage_index].unit.decls) |declaration| if (declaration.* == .var_decl and declaration.var_decl.qualifiers.storage == .const_ and std.mem.eql(u8, declaration.var_decl.name, identifier.name)) {
                    break :value self.constantInteger(stage_index, declaration.var_decl.initializer orelse return null, depth + 1);
                };
                break :value null;
            },
            else => null,
        };
    }

    fn link(self: *Program) Error!void {
        self.diagnostics.code = .link;
        for (&self.stages, 0..) |*stage, stage_index| {
            self.context(stage_index);
            for ([_]@FieldType(Global, "kind"){ .input, .output }) |kind| {
                var used: [32]bool = @splat(false);
                for (stage.globals.items) |global| if (global.kind == kind) {
                    if (global.location) |location| {
                        if (used[location]) return self.fail(global.decl.line, global.decl.column, "duplicate interface location", .{});
                        if (stage_index == 1 and kind == .output and location >= 8) return self.fail(global.decl.line, global.decl.column, "fragment output location must be in 0..7", .{});
                        used[location] = true;
                    }
                };
            }
        }
        const fragment = &self.stages[1];
        var linked: [32]bool = @splat(false);
        var output_row: u32 = 1;
        for (self.stages[0].globals.items) |*output| if (output.kind == .output) {
            if (output_row >= 32) return self.fail(output.decl.line, output.decl.column, "vertex outputs exceed 32 signature rows including position", .{});
            output.row = output_row;
            output_row += 1;
        };
        for (fragment.globals.items) |*input| if (input.kind == .input) {
            self.context(1);
            var matched: ?*Global = null;
            for (self.stages[0].globals.items) |*output| if (output.kind == .output) {
                const matches = if (input.location != null and output.location != null) input.location.? == output.location.? else std.mem.eql(u8, input.decl.name, output.decl.name);
                if (matches) {
                    matched = output;
                    break;
                }
            };
            const output = matched orelse return self.fail(input.decl.line, input.decl.column, "fragment input '{s}' has no matching vertex output", .{input.decl.name});
            if (linked[output.row]) return self.fail(input.decl.line, input.decl.column, "multiple fragment inputs match one vertex output", .{});
            linked[output.row] = true;
            if (!self.equivalent(input.typ, output.typ) or (input.decl.qualifiers.interpolation orelse .smooth) != (output.decl.qualifiers.interpolation orelse .smooth)) return self.fail(input.decl.line, input.decl.column, "varying '{s}' has incompatible type or interpolation", .{input.decl.name});
            if (input.location != null) output.location = input.location;
        };
        for (&self.stages, 0..) |*stage, stage_index| for ([_]@FieldType(Global, "kind"){ .input, .output }) |kind| {
            if (stage_index == 1 and kind == .input) continue;
            var used: [32]bool = @splat(false);
            for (stage.globals.items) |global| if (global.kind == kind and global.location != null) {
                if (used[global.location.?]) return self.fail(global.decl.line, global.decl.column, "linked interface locations collide", .{});
                used[global.location.?] = true;
            };
            for (stage.globals.items) |*global| if (global.kind == kind and global.location == null) {
                const limit: usize = if (stage_index == 1 and kind == .output) 8 else 32;
                const location = std.mem.indexOfScalar(bool, used[0..limit], false) orelse return self.fail(global.decl.line, global.decl.column, "too many stage interface elements", .{});
                global.location = @intCast(location);
                used[location] = true;
            };
        };
        for (fragment.globals.items) |*input| if (input.kind == .input) {
            for (self.stages[0].globals.items) |output| if (output.kind == .output) {
                const matches = if (input.location) |location| location == output.location.? else std.mem.eql(u8, input.decl.name, output.decl.name);
                if (matches) {
                    input.location = output.location;
                    input.row = output.row;
                    break;
                }
            };
        };
        self.diagnostics.code = .source;
    }

    fn layoutUniforms(self: *Program) Error!void {
        for (self.stages[0].globals.items) |vertex| if (vertex.kind == .uniform) {
            for (self.stages[1].globals.items) |fragment| if (fragment.kind == .uniform and std.mem.eql(u8, vertex.decl.name, fragment.decl.name) and !self.equivalent(vertex.typ, fragment.typ)) {
                self.context(1);
                return self.fail(fragment.decl.line, fragment.decl.column, "uniform '{s}' differs between stages", .{fragment.decl.name});
            };
        };
        for (&self.stages, 0..) |*stage, stage_index| {
            self.context(stage_index);
            for (stage.globals.items) |global| if (global.kind == .uniform and global.typ.scalar != .sampler) {
                var found = false;
                for (self.uniforms.items) |*uniform| if (std.mem.eql(u8, uniform.name, global.decl.name)) {
                    if (!self.equivalent(uniform.typ, global.typ)) return self.fail(global.decl.line, global.decl.column, "uniform '{s}' differs between stages", .{global.decl.name});
                    uniform.stages |= @as(u32, 1) << @intCast(stage_index);
                    found = true;
                    break;
                };
                if (!found) try self.uniforms.append(self.allocator, .{ .name = global.decl.name, .typ = global.typ, .offset = 0, .size = 0, .array_stride = 0, .matrix_stride = 0, .stages = @as(u32, 1) << @intCast(stage_index) });
            };
        }
        std.mem.sort(Uniform, self.uniforms.items, {}, struct {
            fn less(_: void, left: Uniform, right: Uniform) bool {
                return std.mem.lessThan(u8, left.name, right.name);
            }
        }.less);
        var stages: u32 = 0;
        for (self.uniforms.items) |*uniform| {
            const layout = self.layoutOf(uniform.typ);
            self.uniform_size = place(self.uniform_size, layout);
            uniform.offset = self.uniform_size;
            uniform.size = layout.size;
            uniform.array_stride = layout.array_stride;
            uniform.matrix_stride = layout.matrix_stride;
            self.uniform_size += layout.size;
            stages |= uniform.stages;
        }
        if (self.uniform_size > 65536) return self.fail(1, 1, "global constant buffer exceeds 64 KiB", .{});
        self.uniform_size = align16(self.uniform_size);
        if (self.uniform_size > 0) try self.bindings.append(self.allocator, .{ .name = "Globals", .class = .cbuffer, .binding = 0, .size = self.uniform_size, .stages = stages });
        if (self.opengl) try self.bindings.append(self.allocator, .{ .name = "GlCompat", .class = .cbuffer, .binding = 0, .space = 1, .size = 32, .stages = 3 });
        var sampler_names: std.ArrayList(struct { name: []const u8, binding: ?u32, stages: u32 }) = .empty;
        for (&self.stages, 0..) |*stage, stage_index| for (stage.globals.items) |global| if (global.kind == .uniform and global.typ.scalar == .sampler) {
            if (global.typ.array_len != 0) return self.fail(global.decl.line, global.decl.column, "sampler arrays are not supported", .{});
            var found = false;
            for (sampler_names.items) |*sampler| if (std.mem.eql(u8, sampler.name, global.decl.name)) {
                if (sampler.binding != null and global.binding != null and sampler.binding != global.binding) return self.fail(global.decl.line, global.decl.column, "sampler bindings differ between stages", .{});
                if (global.binding != null) sampler.binding = global.binding;
                sampler.stages |= @as(u32, 1) << @intCast(stage_index);
                found = true;
                break;
            };
            if (!found) try sampler_names.append(self.allocator, .{ .name = global.decl.name, .binding = global.binding, .stages = @as(u32, 1) << @intCast(stage_index) });
        };
        const Sampler = @TypeOf(sampler_names.items[0]);
        std.mem.sort(Sampler, sampler_names.items, {}, struct {
            fn less(_: void, left: Sampler, right: Sampler) bool {
                return std.mem.lessThan(u8, left.name, right.name);
            }
        }.less);
        var used: [32]bool = @splat(false);
        for (sampler_names.items) |sampler| if (sampler.binding) |binding| {
            if (used[binding]) return self.fail(1, 1, "resource binding collision", .{});
            used[binding] = true;
        };
        for (sampler_names.items) |*sampler| {
            if (sampler.binding == null) {
                const binding = std.mem.indexOfScalar(bool, &used, false) orelse return self.fail(1, 1, "too many samplers", .{});
                sampler.binding = @intCast(binding);
                used[binding] = true;
            }
            try self.bindings.append(self.allocator, .{ .name = sampler.name, .class = .srv, .binding = sampler.binding.?, .stages = sampler.stages });
            try self.bindings.append(self.allocator, .{ .name = sampler.name, .class = .sampler, .binding = sampler.binding.?, .stages = sampler.stages });
        }
        for (&self.stages) |*stage| for (stage.globals.items) |*global| if (global.kind == .uniform) {
            if (global.typ.scalar == .sampler) {
                for (sampler_names.items) |sampler| if (std.mem.eql(u8, sampler.name, global.decl.name)) {
                    global.binding = sampler.binding;
                    break;
                };
            } else for (self.uniforms.items) |uniform| {
                if (std.mem.eql(u8, uniform.name, global.decl.name)) {
                    global.offset = uniform.offset;
                    break;
                }
            }
        };
        const roots = self.uniforms.items.len;
        for (0..roots) |index| try self.reflectFields(self.uniforms.items[index]);
    }

    fn reflectFields(self: *Program, parent: Uniform) Error!void {
        if (parent.typ.array_len != 0) return;
        if (parent.typ.scalar != .structure) return;
        for (self.structures.items[parent.typ.structure].fields) |field| {
            const layout = self.layoutOf(field.typ);
            const uniform: Uniform = .{ .name = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ parent.name, field.name }), .typ = field.typ, .offset = parent.offset + field.offset, .size = layout.size, .array_stride = layout.array_stride, .matrix_stride = layout.matrix_stride, .stages = parent.stages };
            try self.uniforms.append(self.allocator, uniform);
            try self.reflectFields(uniform);
        }
    }

    pub fn fail(self: *Program, line: u32, column: u32, comptime format: []const u8, args: anytype) Error {
        try self.diagnostics.errFmt(line, column, format, args);
        return error.InvalidShader;
    }
};

fn lessGlobal(_: void, left: Global, right: Global) bool {
    return std.mem.lessThan(u8, left.decl.name, right.decl.name);
}
pub fn align16(value: u32) u32 {
    return (value + 15) & ~@as(u32, 15);
}
pub fn place(offset: u32, layout: Layout) u32 {
    return if (layout.aggregate or offset % 16 + layout.size > 16) align16(offset) else offset;
}
