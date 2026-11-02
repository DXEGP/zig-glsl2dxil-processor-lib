const std = @import("std");
const ast = @import("ast.zig");
const token = @import("token.zig");
const types = @import("types.zig");
const diag = @import("../diag.zig");

pub const Error = error{ InvalidShader, OutOfMemory };

pub const Parser = struct {
    allocator: std.mem.Allocator,
    tokens: []const token.Token,
    index: usize = 0,
    diagnostics: *diag.Diagnostics,
    struct_names: std.ArrayList([]const u8) = .empty,
    expression_locations: std.AutoHashMapUnmanaged(*const ast.Expr, ast.Location) = .empty,
    statement_locations: std.AutoHashMapUnmanaged(*const ast.Stmt, ast.Location) = .empty,
    nesting: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, tokens: []const token.Token, diagnostics: *diag.Diagnostics) Parser {
        return .{
            .allocator = allocator,
            .tokens = tokens,
            .diagnostics = diagnostics,
        };
    }

    pub fn parse(self: *Parser) Error!*ast.TranslationUnit {
        var decls: std.ArrayList(*ast.Decl) = .empty;
        while (!self.check(.eof)) {
            if (self.checkIdent("precision")) {
                _ = self.advance();
                _ = self.advance();
                _ = self.advance();
                try self.expect(.semicolon, "';'");
                try decls.append(self.allocator, try self.make(ast.Decl, .{ .precision = {} }));
                continue;
            }
            if (self.checkIdent("invariant") and
                self.peekAt(1).kind == .identifier and self.peekAt(2).kind == .semicolon)
            {
                _ = self.advance();
                _ = self.advance();
                _ = self.advance();
                continue;
            }
            try self.parseExternal(&decls);
        }
        const unit = try self.make(ast.TranslationUnit, .{
            .decls = try decls.toOwnedSlice(self.allocator),
            .expression_locations = self.expression_locations,
            .statement_locations = self.statement_locations,
        });
        return unit;
    }

    fn parseExternal(self: *Parser, decls: *std.ArrayList(*ast.Decl)) Error!void {
        const qualifiers = try self.parseQualifiers();
        if (self.checkIdent("struct")) {
            const start = self.advance();
            const struct_decl = try self.parseStruct(start);
            try self.expect(.semicolon, "';' after struct definition");
            try decls.append(self.allocator, try self.make(ast.Decl, .{ .struct_decl = struct_decl }));
            return;
        }
        const typ = try self.parseTypeName();
        const name = try self.expectIdentifier("declaration name");
        if (self.check(.lparen)) {
            const function = try self.parseFunction(typ, name, qualifiers);
            try decls.append(self.allocator, try self.make(ast.Decl, .{ .function = function }));
            return;
        }
        const variables = try self.parseVarDecls(qualifiers, typ, name, true);
        for (variables) |variable| {
            try decls.append(self.allocator, try self.make(ast.Decl, .{ .var_decl = variable }));
        }
    }

    fn parseStruct(self: *Parser, start: token.Token) Error!*ast.StructDecl {
        const name = try self.expectIdentifier("struct name");
        if (self.isStructName(name.text)) {
            return self.fail(name.line, name.column, "struct '{s}' is already declared", .{name.text});
        }
        try self.expect(.lbrace, "'{'");
        var fields: std.ArrayList(ast.StructField) = .empty;
        while (!self.check(.rbrace) and !self.check(.eof)) {
            while (self.checkIdent("highp") or self.checkIdent("mediump") or self.checkIdent("lowp")) {
                _ = self.advance();
            }
            const field_type = try self.parseTypeName();
            const field_name = try self.expectIdentifier("field name");
            var array_len: ?u32 = null;
            if (self.match(.lbracket)) {
                const len_expr = try self.parseAssignment();
                array_len = self.constantInt(len_expr) orelse
                    return self.fail(field_name.line, field_name.column, "array length must be a constant integer", .{});
                if (array_len.? == 0) {
                    return self.fail(field_name.line, field_name.column, "array length must be greater than zero", .{});
                }
                try self.expect(.rbracket, "']'");
            }
            try self.expect(.semicolon, "';' after struct field");
            try fields.append(self.allocator, .{
                .typ = field_type,
                .name = field_name.text,
                .array_len = array_len,
                .line = field_name.line,
                .column = field_name.column,
            });
        }
        try self.expect(.rbrace, "'}'");
        try self.struct_names.append(self.allocator, name.text);
        return self.make(ast.StructDecl, .{
            .name = name.text,
            .fields = try fields.toOwnedSlice(self.allocator),
            .line = start.line,
            .column = start.column,
        });
    }

    fn parseFunction(self: *Parser, return_type: ast.TypeName, name: token.Token, qualifiers: ast.Qualifiers) Error!*ast.Function {
        _ = qualifiers;
        try self.expect(.lparen, "'('");
        var params: std.ArrayList(ast.Parameter) = .empty;
        while (!self.check(.rparen)) {
            var direction: ast.Direction = .in;
            var is_const = false;
            while (self.check(.identifier)) {
                const text = self.peek().text;
                if (std.mem.eql(u8, text, "const")) {
                    is_const = true;
                    _ = self.advance();
                } else if (std.mem.eql(u8, text, "in")) {
                    direction = .in;
                    _ = self.advance();
                } else if (std.mem.eql(u8, text, "out")) {
                    direction = .out;
                    _ = self.advance();
                } else if (std.mem.eql(u8, text, "inout")) {
                    direction = .inout;
                    _ = self.advance();
                } else if (isPrecision(text)) {
                    _ = self.advance();
                } else break;
            }
            const param_type = try self.parseTypeName();
            var param_name: ?[]const u8 = null;
            if (self.check(.identifier)) param_name = self.advance().text;
            var array_len: ?*ast.Expr = null;
            if (self.match(.lbracket)) {
                if (!self.check(.rbracket)) array_len = try self.parseAssignment();
                try self.expect(.rbracket, "']'");
            }
            var qualifiers_out = ast.Qualifiers{};
            if (is_const) qualifiers_out.storage = .const_;
            try params.append(self.allocator, .{
                .qualifiers = qualifiers_out,
                .direction = direction,
                .typ = param_type,
                .name = param_name,
                .array_len = array_len,
            });
            if (!self.match(.comma)) break;
        }
        try self.expect(.rparen, "')'");
        var body: ?*ast.Stmt = null;
        if (self.match(.semicolon)) {
            body = null;
        } else {
            body = try self.parseCompound();
        }
        return self.make(ast.Function, .{
            .name = name.text,
            .return_type = return_type,
            .params = try params.toOwnedSlice(self.allocator),
            .body = body,
            .line = name.line,
            .column = name.column,
        });
    }

    fn parseVarDecls(
        self: *Parser,
        qualifiers: ast.Qualifiers,
        typ: ast.TypeName,
        first_name: token.Token,
        consume_semicolon: bool,
    ) Error![]*ast.VarDecl {
        var list: std.ArrayList(*ast.VarDecl) = .empty;
        var name = first_name;
        while (true) {
            var array_len: ?*ast.Expr = null;
            if (self.match(.lbracket)) {
                if (!self.check(.rbracket)) array_len = try self.parseAssignment();
                try self.expect(.rbracket, "']'");
            }
            var initializer: ?*ast.Expr = null;
            if (self.match(.equal)) initializer = try self.parseAssignment();
            try list.append(self.allocator, try self.make(ast.VarDecl, .{
                .qualifiers = qualifiers,
                .typ = typ,
                .name = name.text,
                .array_len = array_len,
                .initializer = initializer,
                .line = name.line,
                .column = name.column,
            }));
            if (!self.match(.comma)) break;
            name = try self.expectIdentifier("variable name");
        }
        if (consume_semicolon) try self.expect(.semicolon, "';'");
        return list.toOwnedSlice(self.allocator);
    }

    fn parseQualifiers(self: *Parser) Error!ast.Qualifiers {
        var qualifiers = ast.Qualifiers{};
        var layouts: std.ArrayList(ast.Layout) = .empty;
        while (self.check(.identifier)) {
            const text = self.peek().text;
            if (std.mem.eql(u8, text, "layout")) {
                _ = self.advance();
                try self.expect(.lparen, "'('");
                while (!self.check(.rparen)) {
                    const layout_name = try self.expectIdentifier("layout qualifier");
                    var value: ?i64 = null;
                    if (self.match(.equal)) value = try self.parseConstInt();
                    try layouts.append(self.allocator, .{ .name = layout_name.text, .value = value });
                    if (!self.match(.comma)) break;
                }
                try self.expect(.rparen, "')'");
            } else if (std.mem.eql(u8, text, "in")) {
                qualifiers.storage = .in;
                _ = self.advance();
            } else if (std.mem.eql(u8, text, "out")) {
                qualifiers.storage = .out;
                _ = self.advance();
            } else if (std.mem.eql(u8, text, "inout")) {
                qualifiers.storage = .inout;
                _ = self.advance();
            } else if (std.mem.eql(u8, text, "uniform")) {
                qualifiers.storage = .uniform;
                _ = self.advance();
            } else if (std.mem.eql(u8, text, "buffer")) {
                qualifiers.storage = .buffer;
                _ = self.advance();
            } else if (std.mem.eql(u8, text, "shared")) {
                qualifiers.storage = .shared;
                _ = self.advance();
            } else if (std.mem.eql(u8, text, "attribute")) {
                qualifiers.storage = .attribute;
                _ = self.advance();
            } else if (std.mem.eql(u8, text, "varying")) {
                qualifiers.storage = .varying;
                _ = self.advance();
            } else if (std.mem.eql(u8, text, "const")) {
                qualifiers.storage = .const_;
                _ = self.advance();
            } else if (std.mem.eql(u8, text, "smooth")) {
                qualifiers.interpolation = .smooth;
                _ = self.advance();
            } else if (std.mem.eql(u8, text, "flat")) {
                qualifiers.interpolation = .flat;
                _ = self.advance();
            } else if (std.mem.eql(u8, text, "noperspective")) {
                qualifiers.interpolation = .noperspective;
                _ = self.advance();
            } else if (std.mem.eql(u8, text, "invariant")) {
                qualifiers.invariant = true;
                _ = self.advance();
            } else if (std.mem.eql(u8, text, "precise")) {
                qualifiers.precise = true;
                _ = self.advance();
            } else if (isPrecision(text) or std.mem.eql(u8, text, "centroid") or std.mem.eql(u8, text, "sample")) {
                _ = self.advance();
            } else if (std.mem.eql(u8, text, "precision")) {
                break;
            } else break;
        }
        qualifiers.layout = try layouts.toOwnedSlice(self.allocator);
        return qualifiers;
    }

    fn parseTypeName(self: *Parser) Error!ast.TypeName {
        const token_name = try self.expectIdentifier("type name");
        if (!types.isBuiltinTypeName(token_name.text) and !self.isStructName(token_name.text)) {
            return self.fail(token_name.line, token_name.column, "unknown type '{s}'", .{token_name.text});
        }
        return .{ .name = token_name.text, .line = token_name.line, .column = token_name.column };
    }

    fn parseStatement(self: *Parser) Error!*ast.Stmt {
        try self.enter();
        defer self.nesting -= 1;
        const start = self.peek();
        const statement = try self.parseStatementInner();
        try self.statement_locations.put(self.allocator, statement, .{ .line = start.line, .column = start.column });
        return statement;
    }

    fn parseStatementInner(self: *Parser) Error!*ast.Stmt {
        if (self.check(.lbrace)) return self.parseCompound();
        if (self.matchIdent("if")) return self.parseIf();
        if (self.matchIdent("for")) return self.parseFor();
        if (self.matchIdent("while")) return self.parseWhile();
        if (self.matchIdent("do")) return self.parseDoWhile();
        if (self.matchIdent("switch")) return self.parseSwitch();
        if (self.matchIdent("return")) {
            const start = self.tokens[self.index - 1];
            var value: ?*ast.Expr = null;
            if (!self.check(.semicolon)) value = try self.parseExpression();
            try self.expect(.semicolon, "';'");
            return self.make(ast.Stmt, .{ .return_stmt = .{ .value = value, .line = start.line } });
        }
        if (self.matchIdent("break")) {
            try self.expect(.semicolon, "';'");
            return self.make(ast.Stmt, .{ .break_stmt = {} });
        }
        if (self.matchIdent("continue")) {
            try self.expect(.semicolon, "';'");
            return self.make(ast.Stmt, .{ .continue_stmt = {} });
        }
        if (self.matchIdent("discard")) {
            try self.expect(.semicolon, "';'");
            return self.make(ast.Stmt, .{ .discard_stmt = {} });
        }
        if (self.matchIdent("case")) {
            const start = self.tokens[self.index - 1];
            const value = try self.parseExpression();
            try self.expect(.colon, "':'");
            return self.make(ast.Stmt, .{ .case_label = .{ .value = value, .line = start.line } });
        }
        if (self.matchIdent("default")) {
            try self.expect(.colon, "':'");
            return self.make(ast.Stmt, .{ .default_label = {} });
        }
        if (self.check(.semicolon)) {
            _ = self.advance();
            return self.make(ast.Stmt, .{ .block = .{ .statements = &.{}, .line = 0 } });
        }
        if (self.checkIdent("precision")) {
            _ = self.advance();
            _ = self.advance();
            _ = self.advance();
            try self.expect(.semicolon, "';'");
            return self.make(ast.Stmt, .{ .block = .{ .statements = &.{}, .line = 0 } });
        }
        if (self.isDeclarationStart()) {
            const qualifiers = try self.parseQualifiers();
            if (self.checkIdent("struct")) {
                return self.fail(self.peek().line, self.peek().column, "local struct declarations are not supported", .{});
            }
            const typ = try self.parseTypeName();
            const name = try self.expectIdentifier("variable name");
            const variables = try self.parseVarDecls(qualifiers, typ, name, true);
            return self.make(ast.Stmt, .{ .decl = variables });
        }
        const expression = try self.parseExpression();
        try self.expect(.semicolon, "';'");
        return self.make(ast.Stmt, .{ .expr = expression });
    }

    fn parseCompound(self: *Parser) Error!*ast.Stmt {
        const start = self.peek();
        try self.expect(.lbrace, "'{'");
        var statements: std.ArrayList(*ast.Stmt) = .empty;
        while (!self.check(.rbrace) and !self.check(.eof)) {
            try statements.append(self.allocator, try self.parseStatement());
        }
        try self.expect(.rbrace, "'}'");
        return self.make(ast.Stmt, .{ .block = .{
            .statements = try statements.toOwnedSlice(self.allocator),
            .line = start.line,
        } });
    }

    fn parseIf(self: *Parser) Error!*ast.Stmt {
        const start = self.tokens[self.index - 1];
        try self.expect(.lparen, "'('");
        const condition = try self.parseExpression();
        try self.expect(.rparen, "')'");
        const then_branch = try self.parseStatement();
        var else_branch: ?*ast.Stmt = null;
        if (self.matchIdent("else")) else_branch = try self.parseStatement();
        return self.make(ast.Stmt, .{ .if_stmt = .{
            .condition = condition,
            .then_branch = then_branch,
            .else_branch = else_branch,
            .line = start.line,
        } });
    }

    fn parseFor(self: *Parser) Error!*ast.Stmt {
        const start = self.tokens[self.index - 1];
        try self.expect(.lparen, "'('");
        var init_stmt: ?*ast.Stmt = null;
        if (!self.check(.semicolon)) {
            if (self.isDeclarationStart()) {
                const qualifiers = try self.parseQualifiers();
                const typ = try self.parseTypeName();
                const name = try self.expectIdentifier("variable name");
                const variables = try self.parseVarDecls(qualifiers, typ, name, true);
                init_stmt = try self.make(ast.Stmt, .{ .decl = variables });
            } else {
                const expression = try self.parseExpression();
                try self.expect(.semicolon, "';'");
                init_stmt = try self.make(ast.Stmt, .{ .expr = expression });
            }
        } else {
            _ = self.advance();
        }
        var condition: ?*ast.Expr = null;
        if (!self.check(.semicolon)) condition = try self.parseExpression();
        try self.expect(.semicolon, "';'");
        var increment: ?*ast.Expr = null;
        if (!self.check(.rparen)) increment = try self.parseExpression();
        try self.expect(.rparen, "')'");
        const body = try self.parseStatement();
        return self.make(ast.Stmt, .{ .for_stmt = .{
            .init = init_stmt,
            .condition = condition,
            .increment = increment,
            .body = body,
            .line = start.line,
        } });
    }

    fn parseWhile(self: *Parser) Error!*ast.Stmt {
        const start = self.tokens[self.index - 1];
        try self.expect(.lparen, "'('");
        const condition = try self.parseExpression();
        try self.expect(.rparen, "')'");
        const body = try self.parseStatement();
        return self.make(ast.Stmt, .{ .while_stmt = .{
            .condition = condition,
            .body = body,
            .line = start.line,
        } });
    }

    fn parseDoWhile(self: *Parser) Error!*ast.Stmt {
        const start = self.tokens[self.index - 1];
        const body = try self.parseStatement();
        if (!self.matchIdent("while")) {
            return self.fail(start.line, start.column, "expected 'while' after do body", .{});
        }
        try self.expect(.lparen, "'('");
        const condition = try self.parseExpression();
        try self.expect(.rparen, "')'");
        try self.expect(.semicolon, "';'");
        return self.make(ast.Stmt, .{ .do_while = .{
            .body = body,
            .condition = condition,
            .line = start.line,
        } });
    }

    fn parseSwitch(self: *Parser) Error!*ast.Stmt {
        const start = self.tokens[self.index - 1];
        try self.expect(.lparen, "'('");
        const expression = try self.parseExpression();
        try self.expect(.rparen, "')'");
        const body = try self.parseCompound();
        return self.make(ast.Stmt, .{ .switch_stmt = .{
            .expression = expression,
            .body = body,
            .line = start.line,
        } });
    }

    fn parseExpression(self: *Parser) Error!*ast.Expr {
        return self.parseComma();
    }

    fn parseComma(self: *Parser) Error!*ast.Expr {
        var left = try self.parseAssignment();
        while (self.check(.comma)) {
            const op = self.advance();
            const right = try self.parseAssignment();
            left = try self.make(ast.Expr, .{ .comma = .{
                .left = left,
                .right = right,
                .line = op.line,
                .column = op.column,
            } });
        }
        return left;
    }

    fn parseAssignment(self: *Parser) Error!*ast.Expr {
        try self.enter();
        defer self.nesting -= 1;
        const left = try self.parseTernary();
        const op: ?ast.AssignOp = switch (self.peek().kind) {
            .equal => .assign,
            .plus_equal => .add,
            .minus_equal => .subtract,
            .star_equal => .multiply,
            .slash_equal => .divide,
            .percent_equal => .remainder,
            .amp_equal => .bit_and,
            .pipe_equal => .bit_or,
            .caret_equal => .bit_xor,
            .less_less_equal => .shift_left,
            .greater_greater_equal => .shift_right,
            else => null,
        };
        if (op) |assign_op| {
            const op_token = self.advance();
            const value = try self.parseAssignment();
            return self.make(ast.Expr, .{ .assign = .{
                .op = assign_op,
                .target = left,
                .value = value,
                .line = op_token.line,
                .column = op_token.column,
            } });
        }
        return left;
    }

    fn parseTernary(self: *Parser) Error!*ast.Expr {
        const condition = try self.parseBinary(1);
        if (!self.check(.question)) return condition;
        const op = self.advance();
        const then_expr = try self.parseAssignment();
        try self.expect(.colon, "':'");
        const else_expr = try self.parseAssignment();
        return self.make(ast.Expr, .{ .ternary = .{
            .condition = condition,
            .then_expr = then_expr,
            .else_expr = else_expr,
            .line = op.line,
            .column = op.column,
        } });
    }

    const BinaryInfo = struct {
        op: ast.BinaryOp,
        precedence: u8,
    };

    fn binaryInfo(kind: token.Kind) ?BinaryInfo {
        return switch (kind) {
            .pipe_pipe => .{ .op = .logical_or, .precedence = 1 },
            .caret => .{ .op = .bit_xor, .precedence = 5 },
            .amp_amp => .{ .op = .logical_and, .precedence = 3 },
            .pipe => .{ .op = .bit_or, .precedence = 4 },
            .amp => .{ .op = .bit_and, .precedence = 6 },
            .equal_equal => .{ .op = .equal, .precedence = 7 },
            .bang_equal => .{ .op = .not_equal, .precedence = 7 },
            .less => .{ .op = .less, .precedence = 8 },
            .greater => .{ .op = .greater, .precedence = 8 },
            .less_equal => .{ .op = .less_equal, .precedence = 8 },
            .greater_equal => .{ .op = .greater_equal, .precedence = 8 },
            .less_less => .{ .op = .shift_left, .precedence = 9 },
            .greater_greater => .{ .op = .shift_right, .precedence = 9 },
            .plus => .{ .op = .add, .precedence = 10 },
            .minus => .{ .op = .subtract, .precedence = 10 },
            .star => .{ .op = .multiply, .precedence = 11 },
            .slash => .{ .op = .divide, .precedence = 11 },
            .percent => .{ .op = .remainder, .precedence = 11 },
            else => null,
        };
    }

    fn parseBinary(self: *Parser, min_precedence: u8) Error!*ast.Expr {
        var left = try self.parseUnary();
        while (true) {
            const info = binaryInfo(self.peek().kind) orelse break;
            if (info.precedence < min_precedence) break;
            const op = self.advance();
            const right = try self.parseBinary(info.precedence + 1);
            left = try self.make(ast.Expr, .{ .binary = .{
                .op = info.op,
                .left = left,
                .right = right,
                .line = op.line,
                .column = op.column,
            } });
        }
        return left;
    }

    fn parseUnary(self: *Parser) Error!*ast.Expr {
        try self.enter();
        defer self.nesting -= 1;
        const tok = self.peek();
        const unary_op: ?ast.UnaryOp = switch (tok.kind) {
            .plus => .plus,
            .minus => .minus,
            .bang => .logical_not,
            .tilde => .bit_not,
            else => null,
        };
        if (unary_op) |op| {
            _ = self.advance();
            const operand = try self.parseUnary();
            return self.make(ast.Expr, .{ .unary = .{
                .op = op,
                .operand = operand,
                .line = tok.line,
                .column = tok.column,
            } });
        }
        if (self.check(.plus_plus) or self.check(.minus_minus)) {
            const op = self.advance();
            const operand = try self.parseUnary();
            const one = try self.make(ast.Expr, .{ .int_literal = "1" });
            return self.make(ast.Expr, .{ .assign = .{
                .op = if (op.kind == .plus_plus) .add else .subtract,
                .target = operand,
                .value = one,
                .line = op.line,
                .column = op.column,
            } });
        }
        return self.parsePostfix();
    }

    fn parsePostfix(self: *Parser) Error!*ast.Expr {
        var expression = try self.parsePrimary();
        while (true) {
            if (self.match(.lbracket)) {
                const open = self.tokens[self.index - 1];
                const index = try self.parseExpression();
                try self.expect(.rbracket, "']'");
                expression = try self.make(ast.Expr, .{ .index = .{
                    .base = expression,
                    .index = index,
                    .line = open.line,
                    .column = open.column,
                } });
            } else if (self.match(.dot)) {
                const dot = self.tokens[self.index - 1];
                const field = try self.expectIdentifier("field name");
                expression = try self.make(ast.Expr, .{ .member = .{
                    .base = expression,
                    .name = field.text,
                    .line = dot.line,
                    .column = dot.column,
                } });
            } else if (self.check(.plus_plus) or self.check(.minus_minus)) {
                const op = self.advance();
                expression = try self.make(ast.Expr, .{ .postfix = .{
                    .operand = expression,
                    .increment = op.kind == .plus_plus,
                    .line = op.line,
                    .column = op.column,
                } });
                break;
            } else break;
        }
        return expression;
    }

    fn parsePrimary(self: *Parser) Error!*ast.Expr {
        const tok = self.peek();
        switch (tok.kind) {
            .int_literal => {
                _ = self.advance();
                return self.make(ast.Expr, .{ .int_literal = tok.text });
            },
            .uint_literal => {
                _ = self.advance();
                return self.make(ast.Expr, .{ .uint_literal = tok.text });
            },
            .float_literal => {
                _ = self.advance();
                return self.make(ast.Expr, .{ .float_literal = tok.text });
            },
            .identifier => {
                _ = self.advance();
                if (std.mem.eql(u8, tok.text, "true")) {
                    return self.make(ast.Expr, .{ .bool_literal = true });
                }
                if (std.mem.eql(u8, tok.text, "false")) {
                    return self.make(ast.Expr, .{ .bool_literal = false });
                }
                if (self.check(.lparen)) return self.parseCall(tok);
                return self.make(ast.Expr, .{ .identifier = .{
                    .name = tok.text,
                    .line = tok.line,
                    .column = tok.column,
                } });
            },
            .lparen => {
                _ = self.advance();
                const expression = try self.parseExpression();
                try self.expect(.rparen, "')'");
                return expression;
            },
            else => return self.fail(tok.line, tok.column, "expected an expression, found '{s}'", .{describeToken(tok)}),
        }
    }

    fn parseCall(self: *Parser, name: token.Token) Error!*ast.Expr {
        try self.expect(.lparen, "'('");
        var args: std.ArrayList(*ast.Expr) = .empty;
        while (!self.check(.rparen)) {
            try args.append(self.allocator, try self.parseAssignment());
            if (!self.match(.comma)) break;
        }
        try self.expect(.rparen, "')'");
        return self.make(ast.Expr, .{ .call = .{
            .callee = name.text,
            .args = try args.toOwnedSlice(self.allocator),
            .line = name.line,
            .column = name.column,
        } });
    }

    fn parseConstInt(self: *Parser) Error!i64 {
        var negative = false;
        if (self.match(.minus)) negative = true else if (self.match(.plus)) {}
        const tok = self.peek();
        if (tok.kind != .int_literal and tok.kind != .uint_literal) {
            return self.fail(tok.line, tok.column, "expected an integer literal", .{});
        }
        _ = self.advance();
        const value = parseIntLiteral(tok.text) orelse
            return self.fail(tok.line, tok.column, "invalid integer literal '{s}'", .{tok.text});
        return if (negative) -value else value;
    }

    fn constantInt(self: *Parser, expression: *ast.Expr) ?u32 {
        const value = self.evalConst(expression) orelse return null;
        if (value < 0 or value > std.math.maxInt(u32)) return null;
        return @intCast(value);
    }

    fn evalConst(self: *Parser, expression: *ast.Expr) ?i64 {
        _ = self;
        return switch (expression.*) {
            .int_literal => |text| parseIntLiteral(text),
            .uint_literal => |text| parseIntLiteral(text),
            .unary => |unary| blk: {
                const value = evalConstStatic(unary.operand) orelse break :blk null;
                break :blk switch (unary.op) {
                    .plus => value,
                    .minus => -value,
                    .bit_not => ~value,
                    .logical_not => @intFromBool(value == 0),
                };
            },
            .binary => |binary| blk: {
                const left = evalConstStatic(binary.left) orelse break :blk null;
                const right = evalConstStatic(binary.right) orelse break :blk null;
                break :blk switch (binary.op) {
                    .add => left +% right,
                    .subtract => left -% right,
                    .multiply => left *% right,
                    .divide => if (right == 0) null else @divTrunc(left, right),
                    .remainder => if (right == 0) null else @rem(left, right),
                    .shift_left => if (right < 0 or right >= 64) null else left << @intCast(right),
                    .shift_right => if (right < 0 or right >= 64) null else left >> @intCast(right),
                    .bit_and => left & right,
                    .bit_or => left | right,
                    .bit_xor => left ^ right,
                    else => null,
                };
            },
            .ternary => |ternary| blk: {
                const condition = evalConstStatic(ternary.condition) orelse break :blk null;
                break :blk if (condition != 0)
                    evalConstStatic(ternary.then_expr)
                else
                    evalConstStatic(ternary.else_expr);
            },
            else => null,
        };
    }

    fn isDeclarationStart(self: *Parser) bool {
        const tok = self.peek();
        if (tok.kind != .identifier) return false;
        if (isQualifierKeyword(tok.text)) return true;
        if (std.mem.eql(u8, tok.text, "struct")) return true;
        return types.isBuiltinTypeName(tok.text) or self.isStructName(tok.text);
    }

    fn isStructName(self: *const Parser, name: []const u8) bool {
        for (self.struct_names.items) |struct_name| {
            if (std.mem.eql(u8, struct_name, name)) return true;
        }
        return false;
    }

    fn fail(self: *Parser, line: u32, column: u32, comptime fmt: []const u8, args: anytype) Error {
        try self.diagnostics.errFmt(line, column, fmt, args);
        return error.InvalidShader;
    }

    fn enter(self: *Parser) Error!void {
        const location = self.peek();
        if (self.nesting >= 256) return self.fail(location.line, location.column, "parser nesting exceeds resource limit", .{});
        self.nesting += 1;
    }

    fn make(self: *Parser, comptime T: type, value: T) Error!*T {
        const ptr = try self.allocator.create(T);
        errdefer self.allocator.destroy(ptr);
        ptr.* = value;
        if (T == ast.Expr) {
            const location: ast.Location = switch (value) {
                .identifier => |node| .{ .line = node.line, .column = node.column },
                .unary => |node| .{ .line = node.line, .column = node.column },
                .postfix => |node| .{ .line = node.line, .column = node.column },
                .binary => |node| .{ .line = node.line, .column = node.column },
                .assign => |node| .{ .line = node.line, .column = node.column },
                .ternary => |node| .{ .line = node.line, .column = node.column },
                .call => |node| .{ .line = node.line, .column = node.column },
                .member => |node| .{ .line = node.line, .column = node.column },
                .index => |node| .{ .line = node.line, .column = node.column },
                .comma => |node| .{ .line = node.line, .column = node.column },
                else => .{ .line = self.tokens[self.index -| 1].line, .column = self.tokens[self.index -| 1].column },
            };
            try self.expression_locations.put(self.allocator, ptr, location);
        }
        return ptr;
    }

    fn peek(self: *const Parser) token.Token {
        return self.tokens[self.index];
    }

    fn peekAt(self: *const Parser, offset: usize) token.Token {
        const at = self.index + offset;
        if (at >= self.tokens.len) return self.tokens[self.tokens.len - 1];
        return self.tokens[at];
    }

    fn advance(self: *Parser) token.Token {
        const tok = self.tokens[self.index];
        if (tok.kind != .eof) self.index += 1;
        return tok;
    }

    fn check(self: *const Parser, kind: token.Kind) bool {
        return self.peek().kind == kind;
    }

    fn checkIdent(self: *const Parser, text: []const u8) bool {
        const tok = self.peek();
        return tok.kind == .identifier and std.mem.eql(u8, tok.text, text);
    }

    fn match(self: *Parser, kind: token.Kind) bool {
        if (!self.check(kind)) return false;
        _ = self.advance();
        return true;
    }

    fn matchIdent(self: *Parser, text: []const u8) bool {
        if (!self.checkIdent(text)) return false;
        _ = self.advance();
        return true;
    }

    fn expect(self: *Parser, kind: token.Kind, what: []const u8) Error!void {
        if (!self.check(kind)) {
            const tok = self.peek();
            return self.fail(tok.line, tok.column, "expected {s}, found '{s}'", .{ what, describeToken(tok) });
        }
        _ = self.advance();
    }

    fn expectIdentifier(self: *Parser, what: []const u8) Error!token.Token {
        if (!self.check(.identifier)) {
            const tok = self.peek();
            return self.fail(tok.line, tok.column, "expected {s}, found '{s}'", .{ what, describeToken(tok) });
        }
        return self.advance();
    }
};

fn evalConstStatic(expression: *ast.Expr) ?i64 {
    return switch (expression.*) {
        .int_literal => |text| parseIntLiteral(text),
        .uint_literal => |text| parseIntLiteral(text),
        .unary => |unary| blk: {
            const value = evalConstStatic(unary.operand) orelse break :blk null;
            break :blk switch (unary.op) {
                .plus => value,
                .minus => -value,
                .bit_not => ~value,
                .logical_not => @intFromBool(value == 0),
            };
        },
        .binary => |binary| blk: {
            const left = evalConstStatic(binary.left) orelse break :blk null;
            const right = evalConstStatic(binary.right) orelse break :blk null;
            break :blk switch (binary.op) {
                .add => left +% right,
                .subtract => left -% right,
                .multiply => left *% right,
                .divide => if (right == 0) null else @divTrunc(left, right),
                .remainder => if (right == 0) null else @rem(left, right),
                .shift_left => if (right < 0 or right >= 64) null else left << @intCast(right),
                .shift_right => if (right < 0 or right >= 64) null else left >> @intCast(right),
                .bit_and => left & right,
                .bit_or => left | right,
                .bit_xor => left ^ right,
                else => null,
            };
        },
        .ternary => |ternary| blk: {
            const condition = evalConstStatic(ternary.condition) orelse break :blk null;
            break :blk if (condition != 0)
                evalConstStatic(ternary.then_expr)
            else
                evalConstStatic(ternary.else_expr);
        },
        else => null,
    };
}

fn parseIntLiteral(text: []const u8) ?i64 {
    var cleaned = text;
    if (cleaned.len > 0 and (cleaned[cleaned.len - 1] == 'u' or cleaned[cleaned.len - 1] == 'U')) {
        cleaned = cleaned[0 .. cleaned.len - 1];
    }
    if (cleaned.len > 2 and cleaned[0] == '0' and (cleaned[1] == 'x' or cleaned[1] == 'X')) {
        return std.fmt.parseInt(i64, cleaned[2..], 16) catch null;
    }
    return std.fmt.parseInt(i64, cleaned, 10) catch null;
}

fn describeToken(tok: token.Token) []const u8 {
    return if (tok.kind == .eof) "end of file" else tok.text;
}

fn isPrecision(text: []const u8) bool {
    return std.mem.eql(u8, text, "highp") or
        std.mem.eql(u8, text, "mediump") or
        std.mem.eql(u8, text, "lowp");
}

fn isQualifierKeyword(text: []const u8) bool {
    const keywords = [_][]const u8{
        "layout",   "const",  "in",            "out",       "inout",
        "uniform",  "buffer", "shared",        "attribute", "varying",
        "smooth",   "flat",   "noperspective", "invariant", "precise",
        "centroid", "sample", "highp",         "mediump",   "lowp",
    };
    for (keywords) |keyword| {
        if (std.mem.eql(u8, text, keyword)) return true;
    }
    return false;
}

test "parse vertex shader structure" {
    const preprocess = @import("preprocess.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var diagnostics = diag.Diagnostics.init(allocator);
    const result = try preprocess.preprocess(allocator,
        \\#version 330 core
        \\layout(location = 0) in vec3 a_position;
        \\layout(location = 1) in vec2 a_uv;
        \\uniform mat4 u_mvp;
        \\out vec2 v_uv;
        \\void main() {
        \\    v_uv = a_uv;
        \\    gl_Position = u_mvp * vec4(a_position, 1.0);
        \\}
    , &diagnostics);
    const tokens = try token.tokenize(allocator, result.source, &diagnostics);
    var parser = Parser.init(allocator, tokens, &diagnostics);
    const unit = try parser.parse();
    try std.testing.expectEqual(@as(usize, 5), unit.decls.len);
    try std.testing.expect(unit.decls[0].* == .var_decl);
    try std.testing.expect(unit.decls[2].* == .var_decl);
    try std.testing.expect(unit.decls[4].* == .function);
}

test "parse reports unknown type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var diagnostics = diag.Diagnostics.init(allocator);
    const tokens = try token.tokenize(allocator, "unknown_type x;", &diagnostics);
    var parser = Parser.init(allocator, tokens, &diagnostics);
    try std.testing.expectError(error.InvalidShader, parser.parse());
    try std.testing.expect(diagnostics.hasErrors());
}
