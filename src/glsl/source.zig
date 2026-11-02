const std = @import("std");
const diag = @import("../diag.zig");

pub const File = struct { name: []const u8, source: []const u8 };
pub const Define = struct { name: []const u8, value: []const u8 = "1" };
pub const Limits = struct {
    file_bytes: usize = 1024 * 1024,
    input_bytes: usize = 32 * 1024 * 1024,
    output_bytes: usize = 4 * 1024 * 1024,
    tokens: usize = 524288,
    expansions: usize = 1048576,
    include_depth: u32 = 64,
    macro_depth: u32 = 64,
    condition_depth: u32 = 128,
    expression_depth: u32 = 128,
};
pub const Config = struct { files: []const File = &.{}, defines: []const Define = &.{}, include_dirs: []const []const u8 = &.{}, limits: Limits = .{} };
pub const Dependency = struct { name: []const u8, sha256: [32]u8 };
pub const Result = struct { source: []const u8, mappings: []const diag.Mapping, dependencies: []const Dependency, token_count: usize };
pub const Error = error{ InvalidShader, OutOfMemory };
const Token = struct { text: []const u8, origin: diag.Location, offset: usize = 0, hidden: []const []const u8 = &.{} };
const Macro = struct { name: []const u8, parameters: ?[]const []const u8 = null, body: []const Token };
const Condition = struct { parent: bool, active: bool, taken: bool, had_else: bool = false };

pub fn preprocess(allocator: std.mem.Allocator, file: File, config: Config, diagnostics: *diag.Diagnostics) Error!Result {
    var pp: Processor = .{ .allocator = allocator, .config = config, .diagnostics = diagnostics };
    const old_name = diagnostics.source_name;
    const old_map = diagnostics.mappings;
    diagnostics.mappings = &.{};
    defer {
        diagnostics.source_name = old_name;
        diagnostics.mappings = old_map;
    }
    if (config.files.len +| config.defines.len +| config.include_dirs.len > config.limits.tokens) return pp.fail(.{ .source = file.name, .line = 1, .column = 1 }, "preprocessor configuration count limit exceeded", .{});
    var vfs_bytes: usize = 0;
    for (config.files) |entry| {
        if (entry.source.len > config.limits.file_bytes or entry.name.len +| entry.source.len > config.limits.input_bytes -| vfs_bytes) return pp.fail(.{ .source = entry.name, .line = 1, .column = 1 }, "VFS input byte limit exceeded", .{});
        vfs_bytes += entry.name.len + entry.source.len;
        const name = try pp.path(entry.name);
        if (pp.files.contains(name)) return pp.fail(.{ .source = name, .line = 1, .column = 1 }, "duplicate VFS path", .{});
        try pp.files.put(allocator, name, entry.source);
    }
    for (config.defines) |define| {
        const origin: diag.Location = .{ .source = "<configuration>", .line = 1, .column = 1 };
        if (!identifier(define.name) or reserved(define.name)) return pp.fail(origin, "invalid or reserved configuration macro '{s}'", .{define.name});
        if (pp.macros.contains(define.name)) return pp.fail(origin, "duplicate configuration macro '{s}'", .{define.name});
        const body = try pp.scan(define.value, origin.source);
        try pp.macros.put(allocator, define.name, .{ .name = define.name, .body = body });
    }
    try pp.file(try pp.path(if (file.name.len == 0) "source.glsl" else file.name), file.source, 0, false);
    return .{ .source = pp.output.items, .mappings = pp.mappings.items, .dependencies = pp.dependencies.items, .token_count = pp.output_tokens };
}

pub fn canonicalPath(allocator: std.mem.Allocator, input: []const u8) Error![]const u8 {
    if (input.len > 4096) return error.InvalidShader;
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(allocator);
    var split = std.mem.tokenizeAny(u8, input, "/\\");
    while (split.next()) |part| {
        if (std.mem.eql(u8, part, ".")) continue;
        if (std.mem.indexOfScalar(u8, part, ':') != null or std.mem.indexOfScalar(u8, part, 0) != null) return error.InvalidShader;
        if (std.mem.eql(u8, part, "..")) {
            if (parts.items.len == 0) return error.InvalidShader;
            _ = parts.pop();
        } else try parts.append(allocator, part);
    }
    if (parts.items.len == 0) return error.InvalidShader;
    return std.mem.join(allocator, "/", parts.items);
}

const Processor = struct {
    allocator: std.mem.Allocator,
    config: Config,
    diagnostics: *diag.Diagnostics,
    files: std.StringHashMapUnmanaged([]const u8) = .empty,
    macros: std.StringHashMapUnmanaged(Macro) = .empty,
    once: std.StringHashMapUnmanaged(void) = .empty,
    dependencies: std.ArrayList(Dependency) = .empty,
    output: std.ArrayList(u8) = .empty,
    mappings: std.ArrayList(diag.Mapping) = .empty,
    output_line: u32 = 1,
    output_column: u32 = 1,
    input_bytes: usize = 0,
    scanned_tokens: usize = 0,
    output_tokens: usize = 0,
    expansions: usize = 0,
    version: []const u8 = "110",

    fn fail(self: *Processor, origin: diag.Location, comptime format: []const u8, arguments: anytype) Error {
        self.diagnostics.source_name = self.diagnostics.allocator.dupe(u8, origin.source) catch return error.OutOfMemory;
        self.diagnostics.errFmt(origin.line, origin.column, format, arguments) catch return error.OutOfMemory;
        return error.InvalidShader;
    }

    fn path(self: *Processor, input: []const u8) Error![]const u8 {
        return canonicalPath(self.allocator, input) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidShader => self.fail(.{ .source = input, .line = 1, .column = 1 }, "invalid virtual path", .{}),
        };
    }

    fn scan(self: *Processor, raw_input: []const u8, name: []const u8) Error![]const Token {
        if (raw_input.len > self.config.limits.file_bytes or raw_input.len > self.config.limits.input_bytes -| self.input_bytes) return self.fail(.{ .source = name, .line = 1, .column = 1 }, "preprocessor input byte limit exceeded", .{});
        self.input_bytes += raw_input.len;
        var normalized: std.ArrayList(u8) = .empty;
        const Segment = struct { offset: usize, line: u32 };
        var locations: std.ArrayList(Segment) = .empty;
        try locations.append(self.allocator, .{ .offset = 0, .line = 1 });
        var raw_position: usize = 0;
        var physical_line: u32 = 1;
        while (raw_position < raw_input.len) {
            const splice = raw_input[raw_position] == '\\' and raw_position + 1 < raw_input.len and (raw_input[raw_position + 1] == '\n' or raw_input[raw_position + 1] == '\r');
            if (splice) raw_position += 1;
            const character = raw_input[raw_position];
            raw_position += 1;
            if (character == '\n' or character == '\r') {
                if (character == '\r' and raw_position < raw_input.len and raw_input[raw_position] == '\n') raw_position += 1;
                if (!splice) try normalized.append(self.allocator, '\n');
                physical_line += 1;
                try locations.append(self.allocator, .{ .offset = normalized.items.len, .line = physical_line });
            } else try normalized.append(self.allocator, character);
        }
        const input = normalized.items;
        var result: std.ArrayList(Token) = .empty;
        var position: usize = 0;
        var line: u32 = 1;
        var column: u32 = 1;
        var block_comment = false;
        while (position < input.len) {
            var low: usize = 0;
            var high = locations.items.len;
            while (low < high) {
                const middle = low + (high - low) / 2;
                if (locations.items[middle].offset <= position) low = middle + 1 else high = middle;
            }
            const location = locations.items[low - 1];
            line = location.line;
            column = @intCast(position - location.offset + 1);
            const start = position;
            const origin: diag.Location = .{ .source = name, .line = line, .column = column };
            const character = input[position];
            if (character == '\n' or character == '\r') {
                position += 1;
                if (character == '\r' and position < input.len and input[position] == '\n') position += 1;
                if (result.items.len >= self.config.limits.tokens -| self.scanned_tokens) return self.fail(origin, "preprocessor token limit exceeded", .{});
                try result.append(self.allocator, .{ .text = "\n", .origin = origin, .offset = start });
                line += 1;
                column = 1;
                continue;
            }
            if (block_comment) {
                if (character == '*' and position + 1 < input.len and input[position + 1] == '/') {
                    block_comment = false;
                    position += 2;
                    column += 2;
                } else {
                    position += 1;
                    column += 1;
                }
                continue;
            }
            if (character == '/' and position + 1 < input.len and input[position + 1] == '*') {
                block_comment = true;
                position += 2;
                column += 2;
                continue;
            }
            if (character == '/' and position + 1 < input.len and input[position + 1] == '/') {
                while (position < input.len and input[position] != '\r' and input[position] != '\n') : (position += 1) column += 1;
                continue;
            }
            if (std.ascii.isWhitespace(character)) {
                position += 1;
                column += 1;
                continue;
            }
            position += 1;
            if (identStart(character)) {
                while (position < input.len and identContinue(input[position])) : (position += 1) {}
            } else if (std.ascii.isDigit(character) or (character == '.' and position < input.len and std.ascii.isDigit(input[position]))) {
                while (position < input.len) : (position += 1) {
                    const next = input[position];
                    if (std.ascii.isAlphanumeric(next) or next == '.' or next == '_') continue;
                    if ((next == '+' or next == '-') and (input[position - 1] == 'e' or input[position - 1] == 'E')) continue;
                    break;
                }
            } else if (character == '"') {
                while (position < input.len and input[position] != '"' and input[position] != '\n') : (position += 1) {
                    if (input[position] == '\\' and position + 1 < input.len) position += 1;
                }
                if (position == input.len or input[position] != '"') return self.fail(origin, "unterminated quoted token", .{});
                position += 1;
            } else {
                for ([_][]const u8{ "<<=", ">>=", "##", "&&", "||", "==", "!=", "<=", ">=", "<<", ">>", "++", "--", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=" }) |operator| {
                    if (std.mem.startsWith(u8, input[start..], operator)) {
                        position = start + operator.len;
                        break;
                    }
                }
            }
            if (result.items.len >= self.config.limits.tokens -| self.scanned_tokens) return self.fail(origin, "preprocessor token limit exceeded", .{});
            try result.append(self.allocator, .{ .text = input[start..position], .origin = origin, .offset = start });
            column += @intCast(position - start);
        }
        if (block_comment) return self.fail(.{ .source = name, .line = line, .column = column }, "unterminated block comment", .{});
        self.scanned_tokens += result.items.len;
        return result.items;
    }

    fn file(self: *Processor, name: []const u8, input: []const u8, depth: u32, import_once: bool) Error!void {
        if (self.once.contains(name)) return;
        const origin: diag.Location = .{ .source = name, .line = 1, .column = 1 };
        if (input.len > self.config.limits.file_bytes or input.len > self.config.limits.input_bytes -| self.input_bytes) return self.fail(origin, "preprocessor input byte limit exceeded", .{});
        if (depth >= self.config.limits.include_depth) return self.fail(origin, "include depth limit exceeded (possible include cycle)", .{});
        if (import_once) try self.once.put(self.allocator, name, {});
        var known = false;
        for (self.dependencies.items) |dependency| if (std.mem.eql(u8, dependency.name, name)) {
            known = true;
            break;
        };
        if (!known) {
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(input, &digest, .{});
            try self.dependencies.append(self.allocator, .{ .name = name, .sha256 = digest });
        }
        const owned_name = try self.allocator.dupe(u8, name);
        const tokens = try self.scan(try self.allocator.dupe(u8, input), owned_name);
        var conditions: std.ArrayList(Condition) = .empty;
        var pending: std.ArrayList(Token) = .empty;
        var start: usize = 0;
        while (start < tokens.len) {
            var end = start;
            while (end < tokens.len and !eq(tokens[end], "\n")) : (end += 1) {}
            const line = tokens[start..end];
            const active = conditions.items.len == 0 or conditions.items[conditions.items.len - 1].active;
            if (line.len > 0 and eq(line[0], "#")) {
                try self.flush(&pending);
                if (line.len > 1) try self.directive(line[1..], &conditions, active, name, depth);
            } else if (active) {
                try pending.appendSlice(self.allocator, tokens[start..@min(end + 1, tokens.len)]);
            }
            start = end + 1;
        }
        try self.flush(&pending);
        if (conditions.items.len != 0) return self.fail(origin, "unterminated conditional directive", .{});
    }

    fn flush(self: *Processor, pending: *std.ArrayList(Token)) Error!void {
        const expanded = try self.expand(pending.items, &.{}, 0);
        for (expanded) |token| {
            if (token.text.len + 1 > self.config.limits.output_bytes -| self.output.items.len or self.output_tokens >= self.config.limits.tokens) return self.fail(token.origin, "preprocessor output limit exceeded", .{});
            try self.mappings.append(self.allocator, .{ .line = self.output_line, .column = self.output_column, .origin = token.origin });
            try self.output.appendSlice(self.allocator, token.text);
            if (eq(token, "\n")) {
                self.output_line += 1;
                self.output_column = 1;
            } else {
                try self.output.append(self.allocator, ' ');
                self.output_column += @intCast(token.text.len + 1);
                self.output_tokens += 1;
            }
        }
        pending.clearRetainingCapacity();
    }

    fn directive(self: *Processor, tokens: []const Token, conditions: *std.ArrayList(Condition), active: bool, name: []const u8, depth: u32) Error!void {
        const command = tokens[0];
        const args = tokens[1..];
        if (eq(command, "if") or eq(command, "ifdef") or eq(command, "ifndef")) {
            if (conditions.items.len >= self.config.limits.condition_depth) return self.fail(command.origin, "conditional depth limit exceeded", .{});
            var value = false;
            if (eq(command, "if")) {
                if (active) value = (try self.evaluate(args)) != 0;
            } else {
                if (args.len != 1 or !identifier(args[0].text)) return self.fail(command.origin, "expected a conditional macro name", .{});
                value = self.defined(args[0].text);
                if (eq(command, "ifndef")) value = !value;
            }
            try conditions.append(self.allocator, .{ .parent = active, .active = active and value, .taken = active and value });
        } else if (eq(command, "else") or eq(command, "elif") or eq(command, "endif")) {
            if (conditions.items.len == 0) return self.fail(command.origin, "unmatched #{s}", .{command.text});
            if (eq(command, "endif")) {
                if (args.len != 0) return self.fail(command.origin, "unexpected tokens after #endif", .{});
                _ = conditions.pop();
                return;
            }
            const condition = &conditions.items[conditions.items.len - 1];
            if (condition.had_else) return self.fail(command.origin, "conditional directive after #else", .{});
            var value = true;
            if (eq(command, "elif") and condition.parent and !condition.taken) value = (try self.evaluate(args)) != 0;
            if (eq(command, "else")) {
                if (args.len != 0) return self.fail(command.origin, "unexpected tokens after #else", .{});
                condition.had_else = true;
            }
            condition.active = condition.parent and !condition.taken and value;
            condition.taken = condition.taken or condition.active;
        } else if (!active) {
            return;
        } else if (eq(command, "define")) {
            if (args.len == 0 or !identifier(args[0].text) or reserved(args[0].text)) return self.fail(command.origin, "invalid or reserved macro name", .{});
            var body_start: usize = 1;
            var parameters: ?[]const []const u8 = null;
            if (args.len > 1 and eq(args[1], "(") and args[1].offset == args[0].offset + args[0].text.len) {
                var names: std.ArrayList([]const u8) = .empty;
                body_start = 2;
                while (body_start < args.len and !eq(args[body_start], ")")) {
                    const parameter = args[body_start];
                    if (!identifier(parameter.text)) return self.fail(parameter.origin, "expected macro parameter (variadic macros unsupported)", .{});
                    for (names.items) |previous| {
                        try self.charge(parameter.origin);
                        if (std.mem.eql(u8, previous, parameter.text)) return self.fail(parameter.origin, "duplicate macro parameter", .{});
                    }
                    try names.append(self.allocator, parameter.text);
                    body_start += 1;
                    if (body_start < args.len and eq(args[body_start], ")")) break;
                    if (body_start >= args.len or !eq(args[body_start], ",")) return self.fail(parameter.origin, "expected ',' in macro parameters", .{});
                    body_start += 1;
                    if (body_start < args.len and eq(args[body_start], ")")) return self.fail(parameter.origin, "trailing macro parameter comma", .{});
                }
                if (body_start >= args.len) return self.fail(command.origin, "unterminated macro parameters", .{});
                body_start += 1;
                parameters = names.items;
            }
            for (args[body_start..]) |token| if (eq(token, "#") or eq(token, "##")) return self.fail(token.origin, "macro stringification and token pasting are unsupported", .{});
            if (self.macros.get(args[0].text)) |previous| {
                var same = previous.body.len == args[body_start..].len and (previous.parameters == null) == (parameters == null);
                if (same) for (previous.body, args[body_start..]) |left, right| {
                    same = same and std.mem.eql(u8, left.text, right.text);
                };
                if (previous.parameters != null and parameters != null) {
                    same = same and previous.parameters.?.len == parameters.?.len;
                    if (same) for (previous.parameters.?, parameters.?) |left, right| {
                        same = same and std.mem.eql(u8, left, right);
                    };
                }
                if (!same) return self.fail(args[0].origin, "incompatible macro redefinition '{s}' (use #undef first)", .{args[0].text});
            }
            try self.macros.put(self.allocator, args[0].text, .{ .name = args[0].text, .parameters = parameters, .body = args[body_start..] });
        } else if (eq(command, "undef")) {
            if (args.len != 1 or !identifier(args[0].text) or reserved(args[0].text)) return self.fail(command.origin, "invalid #undef", .{});
            _ = self.macros.remove(args[0].text);
        } else if (eq(command, "include") or eq(command, "moj_import")) {
            const expanded = try self.expand(args, &.{}, 0);
            if (expanded.len == 0) return self.fail(command.origin, "expected include path", .{});
            const quoted = expanded.len == 1 and expanded[0].text.len >= 2 and expanded[0].text[0] == '"';
            var include_name: []const u8 = undefined;
            if (quoted) include_name = expanded[0].text[1 .. expanded[0].text.len - 1] else {
                if (expanded.len < 3 or !eq(expanded[0], "<") or !eq(expanded[expanded.len - 1], ">")) return self.fail(command.origin, "expected quoted or bracketed include path", .{});
                var buffer: std.ArrayList(u8) = .empty;
                for (expanded[1 .. expanded.len - 1]) |token| try buffer.appendSlice(self.allocator, token.text);
                include_name = buffer.items;
            }
            if (eq(command, "moj_import") and !quoted) {
                const separator = std.mem.indexOfScalar(u8, include_name, ':');
                const namespace = if (separator) |index| include_name[0..index] else "minecraft";
                const relative = if (separator) |index| include_name[index + 1 ..] else include_name;
                if (!identifier(namespace)) return self.fail(command.origin, "invalid Minecraft import namespace", .{});
                include_name = try std.fmt.allocPrint(self.allocator, "/assets/{s}/shaders/include/{s}", .{ namespace, relative });
            }
            const resolved = try self.resolve(name, include_name, quoted, command.origin);
            try self.file(resolved, self.files.get(resolved).?, depth + 1, eq(command, "moj_import"));
        } else if (eq(command, "pragma")) {
            if (args.len == 1 and eq(args[0], "once")) try self.once.put(self.allocator, name, {});
        } else if (eq(command, "version")) {
            if (args.len == 0) return self.fail(command.origin, "missing GLSL version", .{});
            if (depth == 0) self.version = args[0].text;
        } else if (eq(command, "extension")) {
            if (args.len != 3 or !eq(args[1], ":")) return self.fail(command.origin, "invalid extension directive", .{});
            if (!eq(args[2], "disable")) return self.fail(command.origin, "unsupported GLSL extension '{s}'", .{args[0].text});
        } else if (eq(command, "line")) {
            return self.fail(command.origin, "explicit #line remapping is unsupported; use VFS source mappings", .{});
        } else if (eq(command, "error")) {
            return self.fail(command.origin, "#error {s}", .{try self.directiveMessage(args)});
        } else if (eq(command, "warning")) {
            self.diagnostics.source_name = try self.diagnostics.allocator.dupe(u8, command.origin.source);
            try self.diagnostics.warnFmt(command.origin.line, command.origin.column, "#warning {s}", .{try self.directiveMessage(args)});
        } else return self.fail(command.origin, "unsupported preprocessor directive '#{s}'", .{command.text});
    }

    fn directiveMessage(self: *Processor, tokens: []const Token) Error![]const u8 {
        var text: std.ArrayList(u8) = .empty;
        for (tokens, 0..) |token, index| {
            if (index > 0) try text.append(self.allocator, ' ');
            try text.appendSlice(self.allocator, token.text);
        }
        return text.items;
    }

    fn resolve(self: *Processor, parent: []const u8, include: []const u8, quoted: bool, origin: diag.Location) Error![]const u8 {
        if (include.len == 0) return self.fail(origin, "empty include path", .{});
        if (include[0] == '/' or include[0] == '\\') {
            const path_name = try self.path(include);
            if (self.files.contains(path_name)) return path_name;
        } else {
            if (quoted) {
                const directory = if (std.mem.lastIndexOfScalar(u8, parent, '/')) |index| parent[0 .. index + 1] else "";
                const path_name = try self.path(try std.mem.concat(self.allocator, u8, &.{ directory, include }));
                if (self.files.contains(path_name)) return path_name;
            }
            const root_name = try self.path(include);
            if (self.files.contains(root_name)) return root_name;
            for (self.config.include_dirs) |directory| {
                const path_name = try self.path(try std.mem.join(self.allocator, "/", &.{ directory, include }));
                if (self.files.contains(path_name)) return path_name;
            }
        }
        return self.fail(origin, "include not found in memory VFS: '{s}'", .{include});
    }

    fn defined(self: *Processor, name: []const u8) bool {
        return reserved(name) or self.macros.contains(name);
    }

    fn charge(self: *Processor, origin: diag.Location) Error!void {
        if (self.expansions >= self.config.limits.expansions) return self.fail(origin, "macro work limit exceeded", .{});
        self.expansions += 1;
    }

    fn expand(self: *Processor, input: []const Token, disabled: []const []const u8, depth: u32) Error![]const Token {
        if (input.len == 0) return &.{};
        if (depth >= self.config.limits.macro_depth) return self.fail(input[0].origin, "macro expansion depth limit exceeded", .{});
        var work: std.ArrayList(Token) = .empty;
        try work.appendSlice(self.allocator, input);
        var output: std.ArrayList(Token) = .empty;
        var position: usize = 0;
        while (position < work.items.len) {
            const tokens = work.items;
            const token = tokens[position];
            try self.charge(token.origin);
            if (reserved(token.text)) {
                var replacement = token;
                var file_number: usize = 0;
                for (self.dependencies.items, 0..) |dependency, index| if (std.mem.eql(u8, dependency.name, token.origin.source)) {
                    file_number = index;
                    break;
                };
                replacement.text = if (eq(token, "__VERSION__")) self.version else try std.fmt.allocPrint(self.allocator, "{d}", .{if (eq(token, "__LINE__")) @as(usize, token.origin.line) else file_number});
                try output.append(self.allocator, replacement);
                position += 1;
                continue;
            }
            var suppressed = false;
            for (disabled) |name| if (std.mem.eql(u8, name, token.text)) {
                suppressed = true;
                break;
            };
            for (token.hidden) |name| if (std.mem.eql(u8, name, token.text)) {
                suppressed = true;
                break;
            };
            const macro = if (suppressed) null else self.macros.get(token.text);
            if (macro) |definition| {
                var replacement: std.ArrayList(Token) = .empty;
                var consumed = position + 1;
                if (definition.parameters) |parameters| {
                    var open = position + 1;
                    while (open < tokens.len and eq(tokens[open], "\n")) : (open += 1) {}
                    if (open >= tokens.len or !eq(tokens[open], "(")) {
                        try output.append(self.allocator, token);
                        position += 1;
                        continue;
                    }
                    var arguments: std.ArrayList([]const Token) = .empty;
                    var argument_start = open + 1;
                    var cursor = argument_start;
                    var nesting: u32 = 0;
                    while (cursor < tokens.len) : (cursor += 1) {
                        if (eq(tokens[cursor], "(") or eq(tokens[cursor], ")")) {
                            if (eq(tokens[cursor], "(")) nesting += 1 else if (nesting > 0) nesting -= 1 else break;
                        }
                        if (eq(tokens[cursor], ",") and nesting == 0) {
                            try arguments.append(self.allocator, tokens[argument_start..cursor]);
                            argument_start = cursor + 1;
                        }
                    }
                    if (cursor == tokens.len) return self.fail(token.origin, "unterminated macro invocation", .{});
                    var has_argument = false;
                    for (tokens[argument_start..cursor]) |argument_token| if (!eq(argument_token, "\n")) {
                        has_argument = true;
                        break;
                    };
                    if (has_argument or parameters.len != 0 or arguments.items.len != 0) try arguments.append(self.allocator, tokens[argument_start..cursor]);
                    if (arguments.items.len != parameters.len) return self.fail(token.origin, "macro argument count mismatch for '{s}'", .{token.text});
                    for (arguments.items) |*argument| {
                        var compact: std.ArrayList(Token) = .empty;
                        for (argument.*) |item| if (!eq(item, "\n")) try compact.append(self.allocator, item);
                        argument.* = try self.expand(compact.items, disabled, depth + 1);
                    }
                    for (definition.body) |body_token| {
                        try self.charge(token.origin);
                        var matched = false;
                        for (parameters, arguments.items) |parameter, argument| {
                            try self.charge(token.origin);
                            if (std.mem.eql(u8, parameter, body_token.text)) {
                                if (argument.len > self.config.limits.tokens -| replacement.items.len) return self.fail(token.origin, "macro substitution token limit exceeded", .{});
                                try replacement.appendSlice(self.allocator, argument);
                                matched = true;
                                break;
                            }
                        }
                        if (!matched) {
                            if (replacement.items.len >= self.config.limits.tokens) return self.fail(token.origin, "macro substitution token limit exceeded", .{});
                            try replacement.append(self.allocator, body_token);
                        }
                    }
                    consumed = cursor + 1;
                } else try replacement.appendSlice(self.allocator, definition.body);
                for (replacement.items) |*item| {
                    item.origin = token.origin;
                    const hidden = try self.allocator.alloc([]const u8, item.hidden.len + token.hidden.len + 1);
                    @memcpy(hidden[0..item.hidden.len], item.hidden);
                    @memcpy(hidden[item.hidden.len .. hidden.len - 1], token.hidden);
                    hidden[hidden.len - 1] = definition.name;
                    item.hidden = hidden;
                    if (hidden.len > self.config.limits.macro_depth) return self.fail(token.origin, "macro suppression depth limit exceeded", .{});
                }
                const next_disabled = try self.allocator.alloc([]const u8, disabled.len + 1);
                @memcpy(next_disabled[0..disabled.len], disabled);
                next_disabled[disabled.len] = definition.name;
                const expanded = try self.expand(replacement.items, next_disabled, depth + 1);
                if (expanded.len + work.items.len - (consumed - position) > self.config.limits.tokens) return self.fail(token.origin, "expanded token limit exceeded", .{});
                try work.replaceRange(self.allocator, position, consumed - position, expanded);
            } else {
                try output.append(self.allocator, token);
                position += 1;
            }
            if (output.items.len > self.config.limits.tokens) return self.fail(token.origin, "expanded token limit exceeded", .{});
        }
        return output.items;
    }

    fn evaluate(self: *Processor, input: []const Token) Error!i64 {
        if (input.len == 0) return self.fail(.{ .source = self.diagnostics.source_name, .line = 1, .column = 1 }, "empty preprocessor expression", .{});
        var tokens: std.ArrayList(Token) = .empty;
        var position: usize = 0;
        while (position < input.len) : (position += 1) {
            var token = input[position];
            if (eq(token, "defined")) {
                position += 1;
                const parenthesized = position < input.len and eq(input[position], "(");
                if (parenthesized) position += 1;
                if (position >= input.len or !identifier(input[position].text)) return self.fail(token.origin, "expected macro name after defined", .{});
                token.text = if (self.defined(input[position].text)) "1" else "0";
                if (parenthesized) {
                    position += 1;
                    if (position >= input.len or !eq(input[position], ")")) return self.fail(token.origin, "expected ')' after defined", .{});
                }
            }
            try tokens.append(self.allocator, token);
        }
        var expression: Expression = .{ .pp = self, .tokens = try self.expand(tokens.items, &.{}, 0) };
        const value = try expression.parse(0, true, 0);
        if (expression.position != expression.tokens.len) return self.fail(input[0].origin, "unexpected preprocessor expression token", .{});
        return value;
    }
};

const Expression = struct {
    pp: *Processor,
    tokens: []const Token,
    position: usize = 0,

    fn parse(self: *Expression, minimum: u8, evaluated: bool, depth: u32) Error!i64 {
        if (self.position >= self.tokens.len) return self.pp.fail(.{ .source = "<expression>", .line = 1, .column = 1 }, "incomplete preprocessor expression", .{});
        const token = self.tokens[self.position];
        if (depth >= self.pp.config.limits.expression_depth) return self.pp.fail(token.origin, "expression depth limit exceeded", .{});
        self.position += 1;
        var value: i64 = 0;
        if (eq(token, "(")) {
            value = try self.parse(0, evaluated, depth + 1);
            if (self.position >= self.tokens.len or !eq(self.tokens[self.position], ")")) return self.pp.fail(token.origin, "missing ')' in expression", .{});
            self.position += 1;
        } else if (eq(token, "!") or eq(token, "~") or eq(token, "+") or eq(token, "-")) {
            const operand = try self.parse(12, evaluated, depth + 1);
            value = if (eq(token, "!")) @intFromBool(operand == 0) else if (eq(token, "~")) ~operand else if (eq(token, "-")) 0 -% operand else operand;
        } else if (identifier(token.text)) {
            value = 0;
        } else {
            const number = std.mem.trimEnd(u8, token.text, "uUlL");
            const unsigned = std.fmt.parseInt(u64, number, 0) catch return self.pp.fail(token.origin, "expected preprocessor integer", .{});
            value = @bitCast(unsigned);
        }
        while (self.position < self.tokens.len) {
            const operator = self.tokens[self.position];
            const priority = precedence(operator.text);
            if (priority == 0 or priority < minimum) break;
            self.position += 1;
            if (eq(operator, "?")) {
                const yes = try self.parse(0, evaluated and value != 0, depth + 1);
                if (self.position >= self.tokens.len or !eq(self.tokens[self.position], ":")) return self.pp.fail(operator.origin, "missing ':' in expression", .{});
                self.position += 1;
                const no = try self.parse(priority, evaluated and value == 0, depth + 1);
                value = if (value != 0) yes else no;
                continue;
            }
            const rhs_evaluated = evaluated and !(eq(operator, "&&") and value == 0) and !(eq(operator, "||") and value != 0);
            const right = try self.parse(priority + 1, rhs_evaluated, depth + 1);
            if (!evaluated) {
                value = 0;
                continue;
            }
            if (eq(operator, "&&")) value = @intFromBool(value != 0 and right != 0) else if (eq(operator, "||")) value = @intFromBool(value != 0 or right != 0) else if (eq(operator, "+")) value +%= right else if (eq(operator, "-")) value -%= right else if (eq(operator, "*")) value *%= right else if (eq(operator, "/") or eq(operator, "%")) {
                if (right == 0 or (value == std.math.minInt(i64) and right == -1)) return self.pp.fail(operator.origin, "invalid division in preprocessor expression", .{});
                value = if (eq(operator, "/")) @divTrunc(value, right) else @rem(value, right);
            } else if (eq(operator, "<<") or eq(operator, ">>")) {
                if (right < 0 or right >= 64) return self.pp.fail(operator.origin, "invalid preprocessor shift count", .{});
                value = if (eq(operator, "<<")) value << @intCast(right) else value >> @intCast(right);
            } else if (eq(operator, "&")) value &= right else if (eq(operator, "|")) value |= right else if (eq(operator, "^")) value ^= right else if (eq(operator, "==")) value = @intFromBool(value == right) else if (eq(operator, "!=")) value = @intFromBool(value != right) else if (eq(operator, "<")) value = @intFromBool(value < right) else if (eq(operator, ">")) value = @intFromBool(value > right) else if (eq(operator, "<=")) value = @intFromBool(value <= right) else if (eq(operator, ">=")) value = @intFromBool(value >= right);
        }
        return value;
    }
};

fn precedence(operator: []const u8) u8 {
    const groups = [_][]const []const u8{ &.{"?"}, &.{"||"}, &.{"&&"}, &.{"|"}, &.{"^"}, &.{"&"}, &.{ "==", "!=" }, &.{ "<", ">", "<=", ">=" }, &.{ "<<", ">>" }, &.{ "+", "-" }, &.{ "*", "/", "%" } };
    for (groups, 1..) |group, priority| for (group) |item| if (std.mem.eql(u8, operator, item)) return @intCast(priority);
    return 0;
}
fn eq(token: Token, text: []const u8) bool {
    return std.mem.eql(u8, token.text, text);
}
fn identStart(character: u8) bool {
    return character == '_' or std.ascii.isAlphabetic(character);
}
fn identContinue(character: u8) bool {
    return character == '_' or std.ascii.isAlphanumeric(character);
}
fn identifier(text: []const u8) bool {
    if (text.len == 0 or !identStart(text[0])) return false;
    for (text[1..]) |character| if (!identContinue(character)) return false;
    return true;
}
fn reserved(name: []const u8) bool {
    return std.mem.eql(u8, name, "__VERSION__") or std.mem.eql(u8, name, "__LINE__") or std.mem.eql(u8, name, "__FILE__");
}

test "VFS imports function macros and short circuit preserve original locations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var diagnostics = diag.Diagnostics.init(allocator);
    const result = try preprocess(allocator, .{ .name = "main.glsl", .source = "#version 150\n#moj_import <minecraft:test.glsl>\n#if defined(ENABLE) && (0 && 1/0 || ADD(1,2)==3)\nADD(2,\n3)\n#endif\n" }, .{
        .files = &.{.{ .name = "assets/minecraft/shaders/include/test.glsl", .source = "#pragma once\n#define ADD(a,b) ((a)+(b))\nfloat included;\n" }},
        .defines = &.{.{ .name = "ENABLE" }},
    }, &diagnostics);
    try std.testing.expectEqual(@as(usize, 2), result.dependencies.len);
    try std.testing.expect(std.mem.indexOf(u8, result.source, "( ( 2 ) + ( 3 ) )") != null);
    try std.testing.expectEqualStrings("assets/minecraft/shaders/include/test.glsl", result.mappings[0].origin.source);
    try std.testing.expectEqual(@as(u32, 3), result.mappings[0].origin.line);
}

test "VFS rejects traversal cycles bad conditionals and bounded macro work" {
    const cases = [_][]const u8{ "#include \"../escape\"", "#else", "#if 1\n#else\n#else\n#endif", "#define F(a,b) a\nF(1)", "#if 1/0\n#endif", "#if 1<<64\n#endif", "#define F(a) a##a", "#include \"cycle\"" };
    for (cases) |input| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var diagnostics = diag.Diagnostics.init(arena.allocator());
        try std.testing.expectError(error.InvalidShader, preprocess(arena.allocator(), .{ .name = "main", .source = input }, .{ .files = &.{.{ .name = "cycle", .source = "#include \"cycle\"" }}, .limits = .{ .include_depth = 4 } }, &diagnostics));
        try std.testing.expect(diagnostics.hasErrors());
    }
}

test "macro aliases nested calls recursion suppression continuations and numeric tokens" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var diagnostics = diag.Diagnostics.init(allocator);
    const result = try preprocess(allocator, .{ .name = "main", .source = "#define A F\n#define F(x) x+x\n#define X Y\n#define Y X\n#define SCALE \\\n2\nA(2) F(F(1)) X SCALE 1e-3 0xFFu\n#if 1 ? 1 : 1/0\npassed\n#endif" }, .{}, &diagnostics);
    try std.testing.expect(std.mem.indexOf(u8, result.source, "2 + 2 1 + 1 + 1 + 1 X 2 1e-3 0xFFu") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.source, "passed") != null);
    try std.testing.expect(!diagnostics.hasErrors());
    const spliced = try preprocess(allocator, .{ .name = "spliced", .source = "#define LO\\\nNG 4\\\r\n2\nLONG __LINE__\n" }, .{}, &diagnostics);
    try std.testing.expect(std.mem.indexOf(u8, spliced.source, "42 4") != null);
    const empty = try preprocess(allocator, .{ .name = "empty", .source = "#define F() 42\nF(\n)\n" }, .{}, &diagnostics);
    try std.testing.expect(std.mem.indexOf(u8, empty.source, "42") != null);
}

test "preprocessing limits all fail with diagnostics" {
    const configurations = [_]Config{
        .{ .limits = .{ .file_bytes = 1 } },
        .{ .limits = .{ .input_bytes = 1 } },
        .{ .limits = .{ .output_bytes = 1 } },
        .{ .limits = .{ .tokens = 1 } },
        .{ .limits = .{ .expansions = 1 } },
        .{ .limits = .{ .include_depth = 0 } },
        .{ .limits = .{ .macro_depth = 0 } },
        .{ .limits = .{ .condition_depth = 0 } },
        .{ .limits = .{ .expression_depth = 0 } },
    };
    for (configurations) |config| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var diagnostics = diag.Diagnostics.init(arena.allocator());
        try std.testing.expectError(error.InvalidShader, preprocess(arena.allocator(), .{ .name = "main", .source = "#if 1\nfloat x;\n#endif\n" }, config, &diagnostics));
        try std.testing.expect(diagnostics.hasErrors());
    }
}
