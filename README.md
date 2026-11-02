> [!Caution]
> This is a **pure-vibed** project, so don't have too high expectations for it. If you really need it, it's better to just honestly use SPIR-V as an intermediate.

# glsl2hlsl

[English](README.md) | [简体中文](README_zh.md)

A GLSL-to-HLSL converter written in pure Zig 0.17.0. It does not call shaderc, SPIRV-Cross, or DXC: it preprocesses GLSL, parses it into an AST, and emits HLSL directly.

The project builds as a library with a C ABI and a header-only C++ wrapper. The C header requires C23; the C++ wrapper requires C++23 and is tested with C++26. Stage 1 covers common vertex and fragment shader constructs: uniforms and samplers, stage inputs and outputs, matrix and vector constructors, common intrinsics, texture sampling, and control flow.

## Requirements

- Zig 0.17.0
- C23 for C consumers
- C++23 or newer for C++ consumers; C++26 is tested

The installed headers reject older language standards at compile time.

## Build

```powershell
zig build -Doptimize=ReleaseSafe
```

Artifacts:

| Path | Contents |
| --- | --- |
| `zig-out\lib\glsl2hlsl.lib` | Static library |
| `zig-out\include\glsl2hlsl\glsl2hlsl.h` | C23 header |
| `zig-out\include\glsl2hlsl\glsl2hlsl.hpp` | C++23 header-only wrapper |

Use `-Dshared=true` for a DLL and import library, or `-Dcli=true` to also build the command-line tool.

## Usage

```cpp
#include <glsl2hlsl/glsl2hlsl.hpp>

glsl2hlsl::Result result =
    glsl2hlsl::convert(source, glsl2hlsl::Stage::Fragment);

if (!result) {
    for (const auto &diagnostic : result.diagnostics) {
        // diagnostic.line / column / message
    }
}
std::cout << result.output;
```

The C ABI owns the result memory; release it with `glsl2hlsl_result_free`. The C++ wrapper handles that automatically.

```c
glsl2hlsl_result result = {};
if (glsl2hlsl_convert(source, length, GLSL2HLSL_STAGE_FRAGMENT, &result)
        == GLSL2HLSL_STATUS_OK) {
    fwrite(result.output, 1, result.output_length, stdout);
}
glsl2hlsl_result_free(&result);
```

Command-line tool:

```powershell
zig build -Dcli=true
.\zig-out\bin\glsl2hlsl.exe shader.vert
.\zig-out\bin\glsl2hlsl.exe shader.frag -o shader.hlsl -s fragment
```

## Documentation

Detailed documentation is currently in Chinese:

- [docs/README.md](docs/README.md): project overview and layout
- [docs/usage.md](docs/usage.md): CLI, stage inference, and Zig API
- [docs/cpp-api.md](docs/cpp-api.md): C ABI, C++ wrapper, linking, and ownership
- [docs/design.md](docs/design.md): implementation and design decisions
- [docs/glsl-hlsl-mapping.md](docs/glsl-hlsl-mapping.md): GLSL-to-HLSL mapping rules
- [docs/dxil.md](docs/dxil.md): pure Zig DXIL compilation, reflection, OpenGL state mapping, and hardware acceptance
- [docs/m4.md](docs/m4.md): memory VFS/macros, bounded sessions, Minecraft/Iris support matrix, and reproducible benchmarks

See [README_zh.md](README_zh.md) for this README in Chinese.

## Testing

```powershell
zig build test
zig build c-test
zig build cpp-test
powershell -File tests/run.ps1
```

`cpp-test` builds the same interoperability test with both `-std=c++23` and `-std=c++26`. `tests/run.ps1` also converts every shader under `tests/shaders` and `examples`, validating the output with `dxc.exe` when it is available.

The experimental DXIL backend compiles paired GLSL vertex/pixel sources directly to SM 6.5 / DXIL 1.5 or SM 6.9 / DXIL 1.9. It supports typed SSA, functions and control flow, float matrices, reflected uniforms, sampler2D descriptor tables, and configurable OpenGL coordinate/draw state. SM 6.9 retains native float/int vector arithmetic and supports explicitly selected direct descriptor heap indexing. Zig uses `compileGraphics`; C uses `glsl2hlsl_dxil_compile_graphics` or the extended `_ex` request; C++23/26 provides a move-only `GraphicsResult`. Upload uniforms using reflected offsets and strides, and query execution requirements before selecting device and root signature settings.

Run `zig build test c-test cpp-test dxil-c-test dxil-source-fixtures`, `zig build dxil-source-bench -Doptimize=ReleaseSafe`, or `pwsh -NoProfile -File tests/dxil/run.ps1` for Windows validator and hardware acceptance, including the existing 10 shaders and 96 OpenGL state combinations. The script compares layouts, interfaces, pixels and depth across both targets and both SM 6.9 binding modes; it downloads a pinned Agility SDK for the test renderer and requires SM 6.9 hardware for full acceptance. The compiler core has no DXC/LLVM dependency; official tools are used only during development. General GLSL/package compatibility, UBO/SSBO, sampler arrays, nonuniform resource indexing, and dynamic writes to local aggregates remain unsupported; see the [support contract](docs/dxil.md#m2glsl-源码编译与反射) and [SM 6.9 host requirements](docs/dxil.md#m3sm-69-合法化与宿主要求).

## Limitations

The DXIL v2 request adds memory includes, function macros, source mappings, explicit bounded cache sessions and optional safe optimization, preserving existing C ABI layouts. C++ exposes `CompileSession` and additional `GraphicsRequest` fields. Run `pwsh -NoProfile -File tests/dxil/m4.ps1` with the two supplied archives under `example_shaderpack/` for pinned Minecraft 1.21.4 and Iris checks. Currently 28/34 same-stem Minecraft VS/PS pairs compile; iterationRP's 11 passing pairs are discard/no-op stages, and Complementary's 108 pairs remain blocked. See the [M4 contract](docs/m4.md) for inputs, limits, ownership, performance and remaining work; this does not provide whole-game or whole-pack compatibility.

Stage 1 does not support UBO/SSBO blocks, geometry/tessellation/compute shaders, function overloading, dynamic matrix indexing, or image atomics. See the "Unsupported features" section of the mapping document for the full list.
