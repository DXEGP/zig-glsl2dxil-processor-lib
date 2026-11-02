# Repository Guidelines

## Project Structure & Module Organization

This dependency-free Zig GLSL-to-HLSL converter builds primarily as a library.

- `src/glsl/`: preprocessing, tokenization, AST, parsing, and types.
- `src/hlsl/`: HLSL emission; `src/converter.zig` connects the pipeline.
- `src/root.zig`: Zig API; `src/capi.zig`: C ABI; `src/main.zig`: optional CLI.
- `include/glsl2hlsl/`: public C header and header-only C++ wrapper.
- `tests/c/`, `tests/cpp/`, and `tests/shaders/`: interoperability tests and shader fixtures.
- `examples/`: sample shaders and C++ usage; `docs/`: design, usage, and mapping references.

## Build, Test, and Development Commands

Use Zig 0.17.0. C consumers require C23; C++ consumers require C++23 or newer.

- `zig build -Doptimize=ReleaseSafe`: install the static library and headers under `zig-out/`.
- `zig build -Dshared=true`: build a shared library.
- `zig build -Dcli=true run -- examples/triangle.vert`: build and run the CLI.
- `zig build test -Dcli=true`: run library and CLI unit tests.
- `zig build c-test`: run C23 interoperability tests.
- `zig build cpp-test`: run interoperability tests under C++23 and C++26.
- `powershell -File tests/run.ps1`: build, run all suites, and convert shader fixtures; validate HLSL with `dxc.exe` when available. Set `DXC` or pass `-Dxc` for an explicit compiler path.

## Coding Style & Naming Conventions

Use four-space indentation and `zig fmt build.zig src`. Follow existing Zig names: `PascalCase` types, `camelCase` functions, and `snake_case` variables and fields. Preserve the `glsl2hlsl_` C API prefix and explicit result ownership. Keep comments minimal; explain design in `docs/`. Update both READMEs when changing shared user-facing instructions.

## Testing Guidelines

Place descriptive `test "behavior description"` blocks alongside Zig implementations, using `std.testing`. Add regression cases for changed conversion behavior and diagnostics. Add `.vert` or `.frag` fixtures under `tests/shaders/`; extend interoperability tests for ABI or wrapper changes. No numeric coverage threshold is configured. C/C++ tests compile with `-Wall -Wextra -Werror`.

## Commit & Pull Request Guidelines

History uses short summaries such as `docs update` and `raised c/cpp standards`, without a strict prefix convention. Keep commits focused and descriptive. PRs should explain the change, link relevant issues, and report validation commands and results, including whether DXC ran. Include shader input/output examples for translation changes.

## Agent Workflow

Before exploration, call `graphflow_context` with the absolute repository `rootDir`; use its summary and anchors. Call `graphflow_plan` for multi-step work and `graphflow_index` after changes. If unavailable, disclose that limitation and use targeted reads.
