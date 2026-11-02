const std = @import("std");
pub const Stage = enum { vertex, fragment };
pub const Location = struct { line: u32, column: u32 };

pub const Storage = enum { const_, in, out, inout, uniform, buffer, shared, attribute, varying };

pub const Interpolation = enum { smooth, flat, noperspective };

pub const Layout = struct {
    name: []const u8,
    value: ?i64 = null,
};

pub const Qualifiers = struct {
    storage: ?Storage = null,
    interpolation: ?Interpolation = null,
    invariant: bool = false,
    precise: bool = false,
    layout: []const Layout = &.{},
};

pub const TypeName = struct {
    name: []const u8,
    line: u32,
    column: u32,
};

pub const Parameter = struct {
    qualifiers: Qualifiers = .{},
    direction: Direction = .in,
    typ: TypeName,
    name: ?[]const u8 = null,
    array_len: ?*Expr = null,
};

pub const Direction = enum { in, out, inout };

pub const Function = struct {
    name: []const u8,
    return_type: TypeName,
    params: []Parameter,
    body: ?*Stmt,
    line: u32,
    column: u32,
};

pub const StructField = struct {
    typ: TypeName,
    name: []const u8,
    array_len: ?u32 = null,
    line: u32,
    column: u32,
};

pub const StructDecl = struct {
    name: []const u8,
    fields: []StructField,
    line: u32,
    column: u32,
};

pub const VarDecl = struct {
    qualifiers: Qualifiers = .{},
    typ: TypeName,
    name: []const u8,
    array_len: ?*Expr = null,
    initializer: ?*Expr = null,
    line: u32,
    column: u32,
};

pub const Decl = union(enum) {
    var_decl: *VarDecl,
    function: *Function,
    struct_decl: *StructDecl,
    precision: void,
};

pub const TranslationUnit = struct {
    decls: []*Decl,
    version: ?[]const u8 = null,
    expression_locations: std.AutoHashMapUnmanaged(*const Expr, Location) = .empty,
    statement_locations: std.AutoHashMapUnmanaged(*const Stmt, Location) = .empty,
};

pub const Expr = union(enum) {
    int_literal: []const u8,
    uint_literal: []const u8,
    float_literal: []const u8,
    bool_literal: bool,
    identifier: Ident,

    unary: Unary,
    postfix: Postfix,
    binary: Binary,
    assign: Assign,
    ternary: Ternary,
    call: Call,
    member: Member,
    index: Index,
    comma: Comma,

    pub fn line(self: *const Expr) u32 {
        return switch (self.*) {
            .int_literal, .uint_literal, .float_literal => 0,
            .bool_literal => 0,
            .identifier => |ident| ident.line,
            .unary => |u| u.line,
            .postfix => |p| p.line,
            .binary => |b| b.line,
            .assign => |a| a.line,
            .ternary => |t| t.line,
            .call => |c| c.line,
            .member => |m| m.line,
            .index => |i| i.line,
            .comma => |c| c.line,
        };
    }
};

pub const Ident = struct {
    name: []const u8,
    line: u32,
    column: u32,
};

pub const UnaryOp = enum { plus, minus, logical_not, bit_not };

pub const Unary = struct {
    op: UnaryOp,
    operand: *Expr,
    line: u32,
    column: u32,
};

pub const Postfix = struct {
    operand: *Expr,
    increment: bool,
    line: u32,
    column: u32,
};

pub const BinaryOp = enum {
    add,
    subtract,
    multiply,
    divide,
    remainder,
    less,
    greater,
    less_equal,
    greater_equal,
    equal,
    not_equal,
    logical_and,
    logical_or,
    logical_xor,
    bit_and,
    bit_or,
    bit_xor,
    shift_left,
    shift_right,
};

pub const Binary = struct {
    op: BinaryOp,
    left: *Expr,
    right: *Expr,
    line: u32,
    column: u32,
};

pub const AssignOp = enum {
    assign,
    add,
    subtract,
    multiply,
    divide,
    remainder,
    bit_and,
    bit_or,
    bit_xor,
    shift_left,
    shift_right,
};

pub const Assign = struct {
    op: AssignOp,
    target: *Expr,
    value: *Expr,
    line: u32,
    column: u32,
};

pub const Ternary = struct {
    condition: *Expr,
    then_expr: *Expr,
    else_expr: *Expr,
    line: u32,
    column: u32,
};

pub const Call = struct {
    callee: []const u8,
    args: []*Expr,
    line: u32,
    column: u32,
};

pub const Member = struct {
    base: *Expr,
    name: []const u8,
    line: u32,
    column: u32,
};

pub const Index = struct {
    base: *Expr,
    index: *Expr,
    line: u32,
    column: u32,
};

pub const Comma = struct {
    left: *Expr,
    right: *Expr,
    line: u32,
    column: u32,
};

pub const Stmt = union(enum) {
    block: Block,
    expr: *Expr,
    decl: []*VarDecl,
    if_stmt: If,
    for_stmt: For,
    while_stmt: While,
    do_while: DoWhile,
    switch_stmt: Switch,
    return_stmt: Return,
    break_stmt: void,
    continue_stmt: void,
    discard_stmt: void,
    case_label: CaseLabel,
    default_label: void,

    pub fn line(self: *const Stmt) u32 {
        return switch (self.*) {
            .block => |b| b.line,
            .expr => |e| e.line(),
            .decl => |d| if (d.len > 0) d[0].line else 0,
            .if_stmt => |s| s.line,
            .for_stmt => |s| s.line,
            .while_stmt => |s| s.line,
            .do_while => |s| s.line,
            .switch_stmt => |s| s.line,
            .return_stmt => |s| s.line,
            .break_stmt, .continue_stmt, .discard_stmt => 0,
            .case_label => |c| c.line,
            .default_label => 0,
        };
    }
};

pub const CaseLabel = struct {
    value: *Expr,
    line: u32,
};

pub const Block = struct {
    statements: []*Stmt,
    line: u32,
};

pub const If = struct {
    condition: *Expr,
    then_branch: *Stmt,
    else_branch: ?*Stmt,
    line: u32,
};

pub const For = struct {
    init: ?*Stmt,
    condition: ?*Expr,
    increment: ?*Expr,
    body: *Stmt,
    line: u32,
};

pub const While = struct {
    condition: *Expr,
    body: *Stmt,
    line: u32,
};

pub const DoWhile = struct {
    body: *Stmt,
    condition: *Expr,
    line: u32,
};

pub const Switch = struct {
    expression: *Expr,
    body: *Stmt,
    line: u32,
};

pub const Return = struct {
    value: ?*Expr,
    line: u32,
};
