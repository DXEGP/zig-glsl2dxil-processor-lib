const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const shared = b.option(bool, "shared", "Build glsl2hlsl as a shared library") orelse false;
    const with_cli = b.option(bool, "cli", "Build the glsl2hlsl command line tool") orelse false;

    const mod = b.addModule("processor", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "glsl2hlsl",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/capi.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .linkage = if (shared) .dynamic else .static,
    });
    b.installArtifact(lib);
    b.installFile("include/glsl2hlsl/glsl2hlsl.h", "include/glsl2hlsl/glsl2hlsl.h");
    b.installFile("include/glsl2hlsl/glsl2hlsl.hpp", "include/glsl2hlsl/glsl2hlsl.hpp");
    b.installFile("docs/dxil-reference-license.txt", "share/glsl2hlsl/dxil-reference-license.txt");

    const test_step = b.step("test", "Run unit tests");
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    test_step.dependOn(&b.addRunArtifact(mod_tests).step);

    const dxil_emit = b.addExecutable(.{
        .name = "dxil-emit",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/dxil/emit.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "processor", .module = mod }},
        }),
    });
    const dxil_run = b.addRunArtifact(dxil_emit);
    dxil_run.setCwd(b.path("."));
    dxil_run.addArg(b.option([]const u8, "dxil-output", "DXIL fixture output directory") orelse "zig-out/dxil");
    b.step("dxil-fixtures", "Emit pure Zig SM 6.5 VS/PS validation fixtures").dependOn(&dxil_run.step);

    const source_emit = b.addExecutable(.{
        .name = "dxil-source-emit",
        .root_module = b.createModule(.{ .root_source_file = b.path("tests/dxil/source_emit.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "processor", .module = mod }} }),
    });
    const source_run = b.addRunArtifact(source_emit);
    source_run.setCwd(b.path("."));
    source_run.addArg("zig-out/dxil/m2");
    b.step("dxil-source-fixtures", "Compile the existing GLSL corpus to paired SM 6.5 DXIL").dependOn(&source_run.step);

    const dxil_bench = b.addExecutable(.{
        .name = "dxil-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/dxil/bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "processor", .module = mod }},
        }),
    });
    b.step("dxil-bench", "Measure uncached DXIL emission without GPU or file I/O").dependOn(&b.addRunArtifact(dxil_bench).step);
    const source_bench = b.addExecutable(.{
        .name = "dxil-source-bench",
        .root_module = b.createModule(.{ .root_source_file = b.path("tests/dxil/source_bench.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "processor", .module = mod }} }),
    });
    const source_bench_run = b.addRunArtifact(source_bench);
    source_bench_run.setCwd(b.path("."));
    b.step("dxil-source-bench", "Measure uncached paired GLSL compilation and requested memory").dependOn(&source_bench_run.step);

    const m4 = b.addExecutable(.{ .name = "dxil-m4", .root_module = b.createModule(.{
        .root_source_file = b.path("tests/dxil/m4.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "processor", .module = mod }},
    }) });
    const m4_run = b.addRunArtifact(m4);
    m4_run.setCwd(b.path("."));
    b.step("dxil-m4", "Audit pinned Minecraft and local Iris packages without modifying sources").dependOn(&m4_run.step);
    const m4_bench = b.addExecutable(.{ .name = "dxil-m4-bench", .root_module = b.createModule(.{
        .root_source_file = b.path("tests/dxil/m4_bench.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "processor", .module = mod }},
    }) });
    const m4_bench_run = b.addRunArtifact(m4_bench);
    m4_bench_run.setCwd(b.path("."));
    b.step("dxil-m4-bench", "Measure real and scaled input compilation, safe optimization and cache separately").dependOn(&m4_bench_run.step);

    if (with_cli) {
        const exe = b.addExecutable(.{
            .name = "glsl2hlsl",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "processor", .module = mod },
                },
            }),
        });
        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        run_cmd.addPassthruArgs();
        const run_step = b.step("run", "Run the converter");
        run_step.dependOn(&run_cmd.step);

        const exe_tests = b.addTest(.{
            .root_module = exe.root_module,
        });
        test_step.dependOn(&b.addRunArtifact(exe_tests).step);
    }

    const c_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    c_mod.addCSourceFile(.{
        .file = b.path("tests/c/interop_test.c"),
        .flags = &.{ "-std=c23", "-Wall", "-Wextra", "-Werror" },
    });
    c_mod.addIncludePath(b.path("include"));

    const c_test = b.addExecutable(.{
        .name = "glsl2hlsl_c_test",
        .root_module = c_mod,
    });
    c_test.root_module.linkLibrary(lib);

    const c_step = b.step("c-test", "Build and run the C interoperability test");
    c_step.dependOn(&b.addRunArtifact(c_test).step);

    const dxil_c_mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    dxil_c_mod.addCSourceFile(.{
        .file = b.path("tests/dxil/capi_test.c"),
        .flags = &.{ "-std=c23", "-Wall", "-Wextra", "-Werror" },
    });
    dxil_c_mod.addIncludePath(b.path("include"));
    dxil_c_mod.linkLibrary(lib);
    const dxil_c_test = b.addExecutable(.{ .name = "glsl2hlsl_dxil_c_test", .root_module = dxil_c_mod });
    b.step("dxil-c-test", "Run the DXIL binary C ABI test").dependOn(&b.addRunArtifact(dxil_c_test).step);

    const cpp23_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    cpp23_mod.addCSourceFile(.{
        .file = b.path("tests/cpp/interop_test.cpp"),
        .flags = &.{ "-std=c++23", "-Wall", "-Wextra", "-Werror" },
    });
    cpp23_mod.addIncludePath(b.path("include"));

    const cpp23_test = b.addExecutable(.{
        .name = "glsl2hlsl_cpp23_test",
        .root_module = cpp23_mod,
    });
    cpp23_test.root_module.linkLibrary(lib);

    const cpp26_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    cpp26_mod.addCSourceFile(.{
        .file = b.path("tests/cpp/interop_test.cpp"),
        .flags = &.{ "-std=c++26", "-Wall", "-Wextra", "-Werror" },
    });
    cpp26_mod.addIncludePath(b.path("include"));

    const cpp26_test = b.addExecutable(.{
        .name = "glsl2hlsl_cpp26_test",
        .root_module = cpp26_mod,
    });
    cpp26_test.root_module.linkLibrary(lib);

    const cpp_step = b.step("cpp-test", "Build and run the C++ interoperability tests");
    cpp_step.dependOn(&b.addRunArtifact(cpp23_test).step);
    cpp_step.dependOn(&b.addRunArtifact(cpp26_test).step);
}
