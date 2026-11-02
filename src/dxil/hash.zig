const std = @import("std");

pub fn retail(data: []const u8) [16]u8 {
    var md5 = std.crypto.hash.Md5.init(.{});
    const tail_length = data.len % 64;
    md5.update(data[0 .. data.len - tail_length]);
    const tail = data[data.len - tail_length ..];
    const byte_count: u32 = @truncate(data.len);
    var block: [64]u8 = @splat(0);
    if (tail_length < 56) {
        std.mem.writeInt(u32, block[0..4], byte_count *% 8, .little);
        @memcpy(block[4..][0..tail_length], tail);
        block[4 + tail_length] = 0x80;
    } else {
        @memcpy(block[0..tail_length], tail);
        block[tail_length] = 0x80;
        md5.update(&block);
        block = @splat(0);
        std.mem.writeInt(u32, block[0..4], byte_count *% 8, .little);
    }
    std.mem.writeInt(u32, block[60..64], 1 | (byte_count *% 2), .little);
    md5.update(&block);
    var result: [16]u8 = undefined;
    for (md5.s, 0..) |word, index| std.mem.writeInt(u32, result[index * 4 ..][0..4], word, .little);
    return result;
}

test "retail hash is distinct from standard MD5 and sensitive to trailing bytes" {
    const first = retail("abc");
    const second = retail("abd");
    try std.testing.expect(!std.mem.eql(u8, &first, &second));
    try std.testing.expect(!std.mem.eql(u8, &first, &std.crypto.hash.Md5.hashResult("abc")));
}

test "retail hash matches pinned DXC known answers" {
    const cases = .{
        .{ "", [_]u32{ 0xf6600d14, 0xbae275b7, 0xd4be4a4e, 0xa1e9b201 } },
        .{ &@as([160]u8, @splat('a')), [_]u32{ 0xa5e5a0bb, 0xd96dd9f8, 0x0b4b7191, 0xd63aa54a } },
        .{ &@as([160]u8, @splat('z')), [_]u32{ 0x58ed1b7a, 0x90ede58b, 0xf9ad857c, 0x5440e613 } },
    };
    inline for (cases) |case| {
        const digest = retail(case[0]);
        for (case[1], 0..) |expected, index| {
            try std.testing.expectEqual(expected, std.mem.readInt(u32, digest[index * 4 ..][0..4], .little));
        }
    }
}
