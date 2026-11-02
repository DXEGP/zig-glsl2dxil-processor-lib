const std = @import("std");

pub const Writer = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    bit_count: usize = 0,
    code_width: u6 = 2,

    pub const Block = struct { length_offset: usize, code_width: u6 };

    pub fn init(allocator: std.mem.Allocator) Writer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Writer) void {
        self.bytes.deinit(self.allocator);
    }

    pub fn bits(self: *Writer, value: u64, width: u7) !void {
        for (0..width) |index| {
            if (self.bit_count % 8 == 0) try self.bytes.append(self.allocator, 0);
            const bit: u8 = @intCast((value >> @intCast(index)) & 1);
            self.bytes.items[self.bit_count / 8] |= bit << @intCast(self.bit_count % 8);
            self.bit_count += 1;
        }
    }

    pub fn vbr(self: *Writer, value: u64, width: u6) !void {
        std.debug.assert(width >= 2);
        var remaining = value;
        const continuation = @as(u64, 1) << (width - 1);
        while (remaining >= continuation) {
            try self.bits((remaining & (continuation - 1)) | continuation, width);
            remaining >>= width - 1;
        }
        try self.bits(remaining, width);
    }

    pub fn align32(self: *Writer) !void {
        while (self.bit_count % 32 != 0) try self.bits(0, 1);
    }

    pub fn begin(self: *Writer, block_id: u32) !Block {
        try self.bits(1, self.code_width);
        try self.vbr(block_id, 8);
        try self.vbr(3, 4);
        try self.align32();
        const block: Block = .{ .length_offset = self.bytes.items.len, .code_width = self.code_width };
        try self.bits(0, 32);
        self.code_width = 3;
        return block;
    }

    pub fn end(self: *Writer, block: Block) !void {
        try self.bits(0, self.code_width);
        try self.align32();
        const word_count = (self.bytes.items.len - block.length_offset - 4) / 4;
        std.mem.writeInt(u32, self.bytes.items[block.length_offset..][0..4], @intCast(word_count), .little);
        self.code_width = block.code_width;
    }

    pub fn record(self: *Writer, code: u32, operands: []const u64) !void {
        try self.bits(3, self.code_width);
        try self.vbr(code, 6);
        try self.vbr(operands.len, 6);
        for (operands) |operand| try self.vbr(operand, 6);
    }

    pub fn textRecord(self: *Writer, code: u32, prefix: []const u64, text: []const u8) !void {
        try self.bits(3, self.code_width);
        try self.vbr(code, 6);
        try self.vbr(prefix.len + text.len, 6);
        for (prefix) |operand| try self.vbr(operand, 6);
        for (text) |byte| try self.vbr(byte, 6);
    }
};

test "bitstream writes least significant bits and VBR continuation" {
    var writer = Writer.init(std.testing.allocator);
    defer writer.deinit();
    try writer.bits(0b101, 3);
    try writer.vbr(35, 6);
    try writer.align32();
    try std.testing.expectEqualSlices(u8, &.{ 0x1d, 0x03, 0, 0 }, writer.bytes.items);
}

test "nested bitstream blocks patch word lengths and restore code widths" {
    var writer = Writer.init(std.testing.allocator);
    defer writer.deinit();
    const outer = try writer.begin(8);
    const inner = try writer.begin(17);
    try writer.record(2, &.{});
    try writer.end(inner);
    try writer.end(outer);
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, writer.bytes.items[inner.length_offset..][0..4], .little));
    try std.testing.expectEqual(@as(u6, 2), writer.code_width);
}
