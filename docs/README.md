# glsl2hlsl

[English README](../README.md) | [中文 README](../README_zh.md)

纯 Zig（0.17.0）实现的 GLSL 到 HLSL 转换库。当前为第一阶段：覆盖常见顶点/片元着色器的最基本转换。

转换器不调用 shaderc、glslang 或 SPIRV-Cross，也不经过 SPIR-V。实现方式参考 naga 的前端思路：先做预处理与词法分析，再建立 GLSL 语法树，最后直接生成 HLSL 源码。

## 当前能力

- 顶点着色器与片元着色器。
- C23 头文件、C++23 头文件封装，并用 C++26 验证。
- `#version`、对象式 `#define`、`#ifdef` / `#if` / `#elif` / `#else` / `#endif` 等常用预处理指令。
- 标量、向量、矩阵、结构体、数组、函数、控制流。
- 非采样器 uniform 汇总到一个 `cbuffer Globals : register(b0)`。
- 采样器拆分为 `Texture*` 与 `SamplerState`，自动分配 `t` / `s` 寄存器。
- 自动生成入口函数与 `VSInput` / `VSOutput` / `PSInput` / `PSOutput` 结构体及系统语义。
- 矩阵乘法改写为 `mul()`，并处理 GLSL 列主序构造与 HLSL 行主序构造之间的差异。
- 常用内置函数映射（`mix` → `lerp`、`fract` → `frac` 等），以及 `texture` / `textureLod` / `textureGrad` / `texelFetch`。
- 带行号、列号的诊断信息。

## 快速开始

```powershell
zig build -Doptimize=ReleaseSafe
```

默认生成静态库 `zig-out\lib\glsl2hlsl.lib` 与 `zig-out\include\glsl2hlsl\` 下的 C23/C++23 头文件。

```cpp
#include <glsl2hlsl/glsl2hlsl.hpp>

glsl2hlsl::Result result = glsl2hlsl::convert(source, glsl2hlsl::Stage::Fragment);
if (!result) {
    for (const auto &diagnostic : result.diagnostics) {
        // diagnostic.line / column / message
    }
}
std::cout << result.output;
```

需要命令行工具时：

```powershell
zig build -Dcli=true -Doptimize=ReleaseSafe

.\zig-out\bin\glsl2hlsl.exe examples\triangle.vert -o triangle.hlsl
.\zig-out\bin\glsl2hlsl.exe examples\triangle.frag -o triangle_ps.hlsl
```

不指定 `-o` 时输出到标准输出。着色器阶段通常可以自动推断，也可以用 `--stage` 显式指定。

生成结果可用 DXC 检查：

```powershell
dxc -T vs_6_0 -E main triangle.hlsl
dxc -T ps_6_0 -E main triangle_ps.hlsl
```

## 目录结构

| 路径 | 内容 |
| --- | --- |
| `src/glsl/preprocess.zig` | 注释剥离、`#version`、对象宏与条件编译 |
| `src/glsl/token.zig` | 词法分析 |
| `src/glsl/ast.zig` | GLSL 语法树定义 |
| `src/glsl/parser.zig` | 递归下降语法分析 |
| `src/glsl/types.zig` | 类型模型与 GLSL→HLSL 类型名 |
| `src/glsl/builtins.zig` | 内置函数分类与名称映射 |
| `src/hlsl/emitter.zig` | 语义收集、入口/IO 生成、HLSL 输出 |
| `src/converter.zig` | 预处理 → 词法 → 语法 → 生成的流水线 |
| `src/capi.zig` | C ABI、结果内存与诊断的生命周期 |
| `src/main.zig` | 命令行入口 |
| `include/glsl2hlsl/` | C23 头文件与 C++23 封装 |
| `examples/` | 示例 GLSL、生成结果与 C++ 调用示例 |
| `tests/shaders/` | 回归测试用着色器 |
| `tests/c/` | C23 互操作测试 |
| `tests/cpp/` | C++23/C++26 互操作测试 |
| `tests/run.ps1` | 运行测试并批量转换、用 DXC 验证 |

## 文档索引

- [用法](usage.md)：命令行、阶段推断、退出码与 Zig API。
- [C/C++ 接口](cpp-api.md)：C ABI、C++ 封装、链接方式与内存管理。
- [设计](design.md)：流水线、模块职责、关键取舍与后续计划。
- [DXIL M0/M1/M2](dxil.md)：纯 Zig SM 6.5 源码编译、固定参考、反射、GL 状态契约与硬件验收。
- [GLSL 与 HLSL 映射](glsl-hlsl-mapping.md)：类型、限定符、内置变量、内置函数、纹理与运算符的完整对照，以及当前不支持的语法。

## 验证

```powershell
zig build test
zig build c-test
zig build cpp-test
powershell -ExecutionPolicy Bypass -File tests\run.ps1
```

`tests/run.ps1` 会自动查找 PATH 或 Vulkan SDK 中的 `dxc.exe`，也可以设置环境变量 `DXC` 显式指定。

## 已知限制

第一阶段有意只实现最常见、语义明确的子集。当前不支持：UBO/SSBO 块、结构体构造函数、函数重载、几何/曲面细分/计算着色器、矩阵动态索引、结构体或数组作为着色器输入输出、shadow sampler、采样器数组、`#include`、函数式宏。完整列表见[映射文档](glsl-hlsl-mapping.md#不支持的特性)。
