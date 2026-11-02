const std = @import("std");
const graphics = @import("graphics.zig");
const diag = @import("../diag.zig");

pub const revision = "processor-m4-cache-v1";
pub const Config = struct { entries: usize = 32, bytes: usize = 64 * 1024 * 1024 };
pub const Stats = struct { hits: usize = 0, misses: usize = 0, evictions: usize = 0, bytes: usize = 0 };
const Entry = struct { key: [32]u8, result: graphics.GraphicsResult, diagnostics: []const diag.Diagnostic, bytes: usize };

pub const Session = struct {
    allocator: std.mem.Allocator,
    config: Config,
    stats: Stats = .{},
    entries: std.ArrayList(Entry) = .empty,

    pub fn init(allocator: std.mem.Allocator, config: Config) Session {
        return .{ .allocator = allocator, .config = config };
    }
    pub fn deinit(self: *Session) void {
        self.clear();
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }
    pub fn clear(self: *Session) void {
        for (self.entries.items) |*entry| entry.result.deinit();
        self.entries.clearRetainingCapacity();
        self.stats.bytes = 0;
    }

    pub fn compile(self: *Session, request: graphics.GraphicsRequest, diagnostics: *diag.Diagnostics) graphics.Error!graphics.GraphicsResult {
        const key = fingerprint(request);
        for (self.entries.items, 0..) |entry, index| if (std.mem.eql(u8, &entry.key, &key)) {
            self.stats.hits += 1;
            if (request.measurement) |measurement| measurement.* = .{ .io = measurement.io };
            for (entry.diagnostics) |diagnostic| {
                var copy = diagnostic;
                copy.source_name = try diagnostics.allocator.dupe(u8, diagnostic.source_name);
                copy.message = try diagnostics.allocator.dupe(u8, diagnostic.message);
                try diagnostics.items.append(diagnostics.allocator, copy);
            }
            const recent = self.entries.orderedRemove(index);
            self.entries.appendAssumeCapacity(recent);
            return self.entries.items[self.entries.items.len - 1].result.retain(self.allocator);
        };
        self.stats.misses += 1;
        const first_diagnostic = diagnostics.items.items.len;
        var result = try graphics.compileGraphics(self.allocator, request, diagnostics);
        errdefer result.deinit();
        const size = result.arena.queryCapacity();
        if (self.config.entries == 0 or size > self.config.bytes) return result;
        const allocator = result.arena.allocator();
        const saved = try allocator.dupe(diag.Diagnostic, diagnostics.items.items[first_diagnostic..]);
        for (saved) |*diagnostic| {
            diagnostic.source_name = try allocator.dupe(u8, diagnostic.source_name);
            diagnostic.message = try allocator.dupe(u8, diagnostic.message);
        }
        const retained_size = result.arena.queryCapacity() + @sizeOf(graphics.GraphicsResult.Storage);
        if (retained_size > self.config.bytes) return result;
        try self.entries.ensureUnusedCapacity(self.allocator, 1);
        const stored = try result.retain(self.allocator);
        while (self.entries.items.len >= self.config.entries or retained_size > self.config.bytes - self.stats.bytes) {
            var victim = self.entries.orderedRemove(0);
            self.stats.bytes -= victim.bytes;
            self.stats.evictions += 1;
            victim.result.deinit();
        }
        self.entries.appendAssumeCapacity(.{ .key = key, .result = stored, .diagnostics = saved, .bytes = retained_size });
        self.stats.bytes += retained_size;
        return result;
    }
};

pub fn fingerprint(request: graphics.GraphicsRequest) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    string(&hash, revision);
    string(&hash, request.vertex.name);
    string(&hash, request.vertex.source);
    string(&hash, request.fragment.name);
    string(&hash, request.fragment.source);
    number(&hash, @backingInt(request.target));
    number(&hash, @backingInt(request.coordinates));
    number(&hash, @backingInt(request.binding_mode));
    number(&hash, request.heap_layout.resource_base);
    number(&hash, request.heap_layout.sampler_base);
    number(&hash, @backingInt(request.optimization));
    const limits = request.preprocessing.limits;
    for ([_]u64{ limits.file_bytes, limits.input_bytes, limits.output_bytes, limits.tokens, limits.expansions, limits.include_depth, limits.macro_depth, limits.condition_depth, limits.expression_depth }) |value| number(&hash, value);
    number(&hash, request.preprocessing.files.len);
    for (request.preprocessing.files) |file| {
        string(&hash, file.name);
        string(&hash, file.source);
    }
    number(&hash, request.preprocessing.defines.len);
    for (request.preprocessing.defines) |define| {
        string(&hash, define.name);
        string(&hash, define.value);
    }
    number(&hash, request.preprocessing.include_dirs.len);
    for (request.preprocessing.include_dirs) |directory| string(&hash, directory);
    return hash.finalResult();
}
fn number(hash: *std.crypto.hash.sha2.Sha256, value: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    hash.update(&bytes);
}
fn string(hash: *std.crypto.hash.sha2.Sha256, value: []const u8) void {
    number(hash, value.len);
    hash.update(value);
}

test "cache eviction and destruction preserve returned binaries and warnings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diagnostics = diag.Diagnostics.init(arena.allocator());
    var session = Session.init(std.testing.allocator, .{ .entries = 1 });
    const request: graphics.GraphicsRequest = .{ .vertex = .{ .source = "#warning test\nvoid main(){gl_Position=vec4(0,0,0,1);}" }, .fragment = .{ .source = "out vec4 c;void main(){c=vec4(1);}" } };
    var first = try session.compile(request, &diagnostics);
    defer first.deinit();
    var second = try session.compile(request, &diagnostics);
    defer second.deinit();
    try std.testing.expectEqual(@as(usize, 1), session.stats.hits);
    try std.testing.expectEqual(@as(usize, 2), diagnostics.items.items.len);
    var changed = request;
    changed.optimization = .safe;
    var third = try session.compile(changed, &diagnostics);
    defer third.deinit();
    try std.testing.expectEqual(@as(usize, 1), session.stats.evictions);
    session.deinit();
    try @import("container.zig").validate(first.vertex);
    try std.testing.expectEqualSlices(u8, first.fragment, second.fragment);
}

test "cache invalidates transitive sources macros names targets limits and optimization" {
    const request: graphics.GraphicsRequest = .{
        .vertex = .{ .name = "v", .source = "void main(){gl_Position=vec4(0,0,0,1);}" },
        .fragment = .{ .name = "f", .source = "#include \"a\"\nout vec4 c;void main(){c=COLOR;}" },
        .preprocessing = .{ .files = &.{ .{ .name = "a", .source = "#include \"b\"" }, .{ .name = "b", .source = "#define COLOR vec4(1)\n" } } },
    };
    const initial = fingerprint(request);
    var changed = request;
    changed.preprocessing.files = &.{ .{ .name = "a", .source = "#include \"b\"" }, .{ .name = "b", .source = "#define COLOR vec4(2)\n" } };
    try std.testing.expect(!std.mem.eql(u8, &initial, &fingerprint(changed)));
    changed = request;
    changed.preprocessing.defines = &.{.{ .name = "CONFIG" }};
    try std.testing.expect(!std.mem.eql(u8, &initial, &fingerprint(changed)));
    changed = request;
    changed.preprocessing.include_dirs = &.{"lib"};
    try std.testing.expect(!std.mem.eql(u8, &initial, &fingerprint(changed)));
    changed = request;
    changed.preprocessing.limits.tokens -= 1;
    try std.testing.expect(!std.mem.eql(u8, &initial, &fingerprint(changed)));
    changed = request;
    changed.vertex.name = "other";
    try std.testing.expect(!std.mem.eql(u8, &initial, &fingerprint(changed)));
    changed = request;
    changed.target = .sm69;
    try std.testing.expect(!std.mem.eql(u8, &initial, &fingerprint(changed)));
    changed = request;
    changed.coordinates = .d3d12_native;
    try std.testing.expect(!std.mem.eql(u8, &initial, &fingerprint(changed)));
    changed = request;
    changed.binding_mode = .direct_heap;
    try std.testing.expect(!std.mem.eql(u8, &initial, &fingerprint(changed)));
    changed = request;
    changed.heap_layout.resource_base = 7;
    try std.testing.expect(!std.mem.eql(u8, &initial, &fingerprint(changed)));
    changed = request;
    changed.optimization = .safe;
    try std.testing.expect(!std.mem.eql(u8, &initial, &fingerprint(changed)));
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diagnostics = diag.Diagnostics.init(arena.allocator());
    var session = Session.init(std.testing.allocator, .{ .bytes = 0 });
    defer session.deinit();
    var first = try session.compile(request, &diagnostics);
    defer first.deinit();
    var second = try session.compile(request, &diagnostics);
    defer second.deinit();
    try std.testing.expectEqual(@as(usize, 0), session.stats.hits);
    var invalid = request;
    invalid.fragment.source = "#include \"missing\"";
    try std.testing.expectError(error.InvalidShader, session.compile(invalid, &diagnostics));
    try std.testing.expectError(error.InvalidShader, session.compile(invalid, &diagnostics));
    try std.testing.expectEqual(@as(usize, 4), session.stats.misses);
}

test "cached macro generated reflection owns caller input text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diagnostics = diag.Diagnostics.init(arena.allocator());
    var session = Session.init(std.testing.allocator, .{});
    defer session.deinit();
    var result: graphics.GraphicsResult = undefined;
    {
        const name = try std.testing.allocator.dupe(u8, "some_uniform");
        defer std.testing.allocator.free(name);
        result = try session.compile(.{
            .vertex = .{ .source = "in vec4 p;void main(){gl_Position=p;}" },
            .fragment = .{ .source = "uniform vec4 NAME;out vec4 c;void main(){c=NAME;}" },
            .preprocessing = .{ .defines = &.{.{ .name = "NAME", .value = name }} },
        }, &diagnostics);
        @memset(name, 'x');
    }
    defer result.deinit();
    try std.testing.expectEqualStrings("some_uniform", result.reflection.uniforms[0].name);
}
