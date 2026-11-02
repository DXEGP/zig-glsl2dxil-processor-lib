const std = @import("std");
const processor = @import("processor");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) return error.ExpectedOutputDirectory;
    try std.Io.Dir.cwd().createDirPath(init.io, args[1]);
    const names = [_][]const u8{ "passthrough.vert.dxil", "constant.frag.dxil", "alternate.frag.dxil" };
    const programs = [_]processor.dxil.Program{
        .vertex_passthrough,
        .{ .fragment_constant = .{ 0.25, 0.5, 0.75, 1 } },
        .{ .fragment_constant = .{ 0.75, 0.25, 0.5, 1 } },
    };
    for (names, programs) |name, program| {
        const bytes = try processor.dxil.emit(allocator, program, .sm65);
        defer allocator.free(bytes);
        const path = try std.fs.path.join(allocator, &.{ args[1], name });
        defer allocator.free(path);
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = bytes });
    }
    var vectors: std.ArrayList(u8) = .empty;
    defer vectors.deinit(allocator);
    for ([_]u32{ 0, 1, 55, 56, 57, 63, 64, 65, 119, 120, 127, 128, 129, 160 }) |length| {
        const input = try allocator.alloc(u8, length);
        defer allocator.free(input);
        for (input, 0..) |*byte, index| byte.* = @truncate(index * 17 + length);
        var header: [4]u8 = undefined;
        std.mem.writeInt(u32, &header, length, .little);
        try vectors.appendSlice(allocator, &header);
        try vectors.appendSlice(allocator, &processor.dxil.retailHash(input));
    }
    const vectors_path = try std.fs.path.join(allocator, &.{ args[1], "retail-vectors.bin" });
    defer allocator.free(vectors_path);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = vectors_path, .data = vectors.items });
}
