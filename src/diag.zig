const std = @import("std");

pub const Kind = enum {
    err,
    warning,
};

pub const Diagnostic = struct {
    kind: Kind,
    line: u32,
    column: u32,
    message: []const u8,
    stage: ?@import("options.zig").Stage = null,
    source_name: []const u8 = "",
    code: Code = .source,
};

pub const Code = enum { source, unsupported, type_mismatch, link, invalid_ir };

pub const Diagnostics = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Diagnostic) = .empty,
    stage: ?@import("options.zig").Stage = null,
    source_name: []const u8 = "",
    code: Code = .source,

    pub fn init(allocator: std.mem.Allocator) Diagnostics {
        return .{ .allocator = allocator };
    }

    pub fn add(self: *Diagnostics, kind: Kind, line: u32, column: u32, message: []const u8) !void {
        try self.items.append(self.allocator, .{
            .kind = kind,
            .line = line,
            .column = column,
            .message = message,
            .stage = self.stage,
            .source_name = self.source_name,
            .code = self.code,
        });
    }

    pub fn addFmt(self: *Diagnostics, kind: Kind, line: u32, column: u32, comptime fmt: []const u8, args: anytype) !void {
        const message = try std.fmt.allocPrint(self.allocator, fmt, args);
        try self.add(kind, line, column, message);
    }

    pub fn err(self: *Diagnostics, line: u32, column: u32, message: []const u8) !void {
        try self.add(.err, line, column, message);
    }

    pub fn errFmt(self: *Diagnostics, line: u32, column: u32, comptime fmt: []const u8, args: anytype) !void {
        try self.addFmt(.err, line, column, fmt, args);
    }

    pub fn warn(self: *Diagnostics, line: u32, column: u32, message: []const u8) !void {
        try self.add(.warning, line, column, message);
    }

    pub fn warnFmt(self: *Diagnostics, line: u32, column: u32, comptime fmt: []const u8, args: anytype) !void {
        try self.addFmt(.warning, line, column, fmt, args);
    }

    pub fn hasErrors(self: *const Diagnostics) bool {
        for (self.items.items) |item| {
            if (item.kind == .err) return true;
        }
        return false;
    }
};
