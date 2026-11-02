const std = @import("std");
const processor = @import("processor");
const graphics = processor.dxil.graphics;
const Package = struct { name: []const u8, sha256: []const u8, files: []const processor.source.File };
const Inputs = struct { packages: []const Package };
const Record = struct {
    package: []const u8,
    vertex: []const u8,
    fragment: []const u8,
    preprocessing: bool = false,
    compiled: bool = false,
    configurations_passed: u32 = 0,
    tokens: usize = 0,
    dependencies: usize = 0,
    empty_output: bool = false,
    dependency_manifest: []const processor.source.Dependency = &.{},
    diagnostics: []const processor.diag.Diagnostic = &.{},
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const json = try std.Io.Dir.cwd().readFileAlloc(init.io, "zig-out/m4/inputs.json", allocator, .limited(64 * 1024 * 1024));
    const inputs = try std.json.parseFromSlice(Inputs, allocator, json, .{ .allocate = .alloc_always });
    var records: std.ArrayList(Record) = .empty;
    var artifacts: std.ArrayList([]const u8) = .empty;
    var unsupported_stages: std.ArrayList(struct { package: []const u8, name: []const u8 }) = .empty;
    for (inputs.value.packages) |package| {
        var supported: usize = 0;
        var rejected: usize = 0;
        for (package.files) |file| {
            if (std.mem.endsWith(u8, file.name, ".csh") or std.mem.endsWith(u8, file.name, ".gsh") or std.mem.endsWith(u8, file.name, ".tcs") or std.mem.endsWith(u8, file.name, ".tes")) try unsupported_stages.append(allocator, .{ .package = package.name, .name = file.name });
        }
        for (package.files) |vertex| {
            if (!std.mem.endsWith(u8, vertex.name, ".vsh")) continue;
            const fragment_name = try std.fmt.allocPrint(allocator, "{s}.fsh", .{vertex.name[0 .. vertex.name.len - 4]});
            const fragment = find(package.files, fragment_name) orelse continue;
            var arena = std.heap.ArenaAllocator.init(init.gpa);
            defer arena.deinit();
            const scratch = arena.allocator();
            var diagnostics = processor.diag.Diagnostics.init(scratch);
            const config: processor.source.Config = .{ .files = package.files, .defines = if (std.mem.startsWith(u8, package.name, "minecraft")) &.{} else &.{ .{ .name = "MC_VERSION", .value = "12104" }, .{ .name = "IS_IRIS" }, .{ .name = "IRIS_VERSION", .value = "10800" } } };
            var record: Record = .{ .package = package.name, .vertex = vertex.name, .fragment = fragment.name };
            const prevertex = processor.source.preprocess(scratch, vertex, config, &diagnostics) catch null;
            const prefragment = if (prevertex != null) processor.source.preprocess(scratch, fragment, config, &diagnostics) catch null else null;
            if (prevertex != null and prefragment != null) {
                record.preprocessing = true;
                record.tokens = prevertex.?.token_count + prefragment.?.token_count;
                record.dependencies = prevertex.?.dependencies.len + prefragment.?.dependencies.len;
                const manifest = try allocator.alloc(processor.source.Dependency, record.dependencies);
                const first_count = prevertex.?.dependencies.len;
                @memcpy(manifest[0..first_count], prevertex.?.dependencies);
                @memcpy(manifest[first_count..], prefragment.?.dependencies);
                for (manifest) |*dependency| dependency.name = try allocator.dupe(u8, dependency.name);
                record.dependency_manifest = manifest;
                var baseline: ?[]const u8 = null;
                for (0..3) |configuration| for ([_]graphics.optimizer.Level{ .none, .safe }) |optimization| {
                    if (diagnostics.hasErrors()) continue;
                    const target: processor.dxil.Target = if (configuration == 0) .sm65 else .sm69;
                    var result = processor.compileGraphics(init.gpa, .{ .vertex = .{ .source = vertex.source, .name = vertex.name }, .fragment = .{ .source = fragment.source, .name = fragment.name }, .preprocessing = config, .target = target, .optimization = optimization, .binding_mode = if (configuration == 2) .direct_heap else .descriptor_tables, .heap_layout = .{ .resource_base = 3, .sampler_base = 5 } }, &diagnostics) catch continue;
                    defer result.deinit();
                    const reflection = result.reflection;
                    record.empty_output = reflection.fragment_outputs.len == 0;
                    const key = try std.json.Stringify.valueAlloc(scratch, .{ .uniforms = reflection.uniforms, .bindings = reflection.bindings, .vertex_inputs = reflection.vertex_inputs, .vertex_outputs = reflection.vertex_outputs, .fragment_inputs = reflection.fragment_inputs, .fragment_outputs = reflection.fragment_outputs }, .{});
                    if (baseline) |expected| {
                        if (!std.mem.eql(u8, expected, key)) return error.ReflectionChanged;
                    } else baseline = key;
                    const directory = try std.fmt.allocPrint(scratch, "zig-out/m4/{s}/{s}/{s}", .{ package.name, if (configuration == 0) "sm65" else if (configuration == 1) "sm69" else "sm69-heap", @tagName(optimization) });
                    try std.Io.Dir.cwd().createDirPath(init.io, directory);
                    const stem = try scratch.dupe(u8, vertex.name[0 .. vertex.name.len - 4]);
                    for (stem) |*character| if (character.* == '/') {
                        character.* = '_';
                    };
                    for ([_][]const u8{ result.vertex, result.fragment }, [_][]const u8{ "vert", "frag" }) |binary, stage| {
                        const path = try std.fmt.allocPrint(scratch, "{s}/{s}.{s}.dxil", .{ directory, stem, stage });
                        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = binary });
                        try artifacts.append(allocator, try allocator.dupe(u8, path));
                    }
                    record.configurations_passed += 1;
                    record.compiled = record.configurations_passed == 6;
                };
            }
            if (record.compiled) supported += 1 else rejected += 1;
            record.diagnostics = try allocator.dupe(processor.diag.Diagnostic, diagnostics.items.items);
            for (@constCast(record.diagnostics)) |*diagnostic| {
                diagnostic.source_name = try allocator.dupe(u8, diagnostic.source_name);
                diagnostic.message = try allocator.dupe(u8, diagnostic.message);
            }
            try records.append(allocator, record);
        }
        const message = try std.fmt.allocPrint(allocator, "package={s} pairs_supported={d} pairs_rejected={d}\n", .{ package.name, supported, rejected });
        try std.Io.File.stdout().writeStreamingAll(init.io, message);
        if (std.mem.eql(u8, package.name, "minecraft-1.21.4") and supported < 28) return error.MinecraftRegression;
        if (std.mem.eql(u8, package.name, "iterationRP-0.8.31") and supported < 11) return error.IrisRegression;
    }
    const report = try std.json.Stringify.valueAlloc(allocator, .{ .schema_version = 1, .scope = "Same-stem .vsh/.fsh pairs only; does not interpret Minecraft program JSON or Iris render graph, properties, textures or multi-pass scheduling", .macro_configuration = "Minecraft: none; Iris: MC_VERSION=12104, IS_IRIS=1, IRIS_VERSION=10800; pack defaults unchanged", .unsupported_stages = unsupported_stages.items, .records = records.items, .artifacts = artifacts.items }, .{ .whitespace = .indent_2 });
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = "zig-out/m4/support.json", .data = report });
}

fn find(files: []const processor.source.File, name: []const u8) ?processor.source.File {
    for (files) |file| if (std.mem.eql(u8, file.name, name)) return file;
    return null;
}
