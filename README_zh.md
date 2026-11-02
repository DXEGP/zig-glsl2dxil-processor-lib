> [!Caution]
> 这是一个**纯-vibe**项目，不要对它抱有太高的期待。如果你真的想要这么做，还是老老实实去研究`wgpu`的`naga`吧。

# glsl2hlsl

[English](README.md) | [简体中文](README_zh.md)

用纯 Zig（0.17.0）实现的 GLSL 到 HLSL 转换库。不调用 shaderc、SPIRV-Cross 或 DXC，直接对 GLSL 源码做预处理、词法分析、语法分析和带类型推断的 HLSL 生成。

项目以库形式构建，提供 C ABI 和头文件式 C++ 封装。C 头文件要求 C23；C++ 封装要求 C++23，并已用 C++26 验证。当前为第一阶段，覆盖常见的顶点/片元着色器写法：uniform 与采样器、stage 输入输出、矩阵与向量构造、常用内置函数、纹理采样和流程控制。

## 要求

- Zig 0.17.0
- C 调用方使用 C23
- C++ 调用方使用 C++23 或更新标准；已验证 C++26

安装后的头文件会在编译期拒绝更低的标准。

## 构建

```powershell
zig build -Doptimize=ReleaseSafe
```

产物：

| 路径 | 内容 |
| --- | --- |
| `zig-out\lib\glsl2hlsl.lib` | 静态库 |
| `zig-out\include\glsl2hlsl\glsl2hlsl.h` | C23 头文件 |
| `zig-out\include\glsl2hlsl\glsl2hlsl.hpp` | C++23 头文件封装 |

需要动态库用 `-Dshared=true`，需要命令行工具用 `-Dcli=true`。

## 使用

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

C ABI 的结果内存由库持有，必须用 `glsl2hlsl_result_free` 释放；C++ 封装会自动处理。

```c
glsl2hlsl_result result = {};
if (glsl2hlsl_convert(source, length, GLSL2HLSL_STAGE_FRAGMENT, &result)
        == GLSL2HLSL_STATUS_OK) {
    fwrite(result.output, 1, result.output_length, stdout);
}
glsl2hlsl_result_free(&result);
```

命令行工具：

```powershell
zig build -Dcli=true
.\zig-out\bin\glsl2hlsl.exe shader.vert
.\zig-out\bin\glsl2hlsl.exe shader.frag -o shader.hlsl -s fragment
```

## 文档

- [docs/README.md](docs/README.md)：项目概览与目录结构
- [docs/usage.md](docs/usage.md)：命令行、阶段推断与 Zig API
- [docs/cpp-api.md](docs/cpp-api.md)：C ABI、C++ 封装、链接与内存管理
- [docs/design.md](docs/design.md)：实现结构与设计取舍
- [docs/glsl-hlsl-mapping.md](docs/glsl-hlsl-mapping.md)：逐项映射规则
- [docs/dxil.md](docs/dxil.md)：纯 Zig DXIL 编译、反射、OpenGL 状态映射与硬件验收

英文 README 见 [README.md](README.md)。

## 测试

```powershell
zig build test
zig build c-test
zig build cpp-test
powershell -File tests/run.ps1
```

`cpp-test` 用 `-std=c++23` 和 `-std=c++26` 分别编译并运行同一份互操作测试。`tests/run.ps1` 还会转换 `tests/shaders` 与 `examples` 下的全部着色器，并在找到 `dxc.exe` 时验证生成的 HLSL。

实验性 DXIL 后端支持将配对 GLSL 顶点/片元源码直接编译为 SM 6.5 / DXIL 1.5 或 SM 6.9 / DXIL 1.9，包含类型化 SSA、函数与控制流、浮点矩阵、uniform 布局反射、sampler2D 描述符表，以及可配置 OpenGL 坐标/绘制状态。SM 6.9 保留原生浮点/整数向量算术，并支持显式选择描述符堆直接索引。Zig 使用 `compileGraphics`，C 使用 `glsl2hlsl_dxil_compile_graphics` 或扩展 `_ex` 请求，C++23/26 提供只移动的 `GraphicsResult`。宿主按反射偏移和步长上传 uniform，并查询执行要求以选择设备与根签名配置。

运行 `zig build test c-test cpp-test dxil-c-test dxil-source-fixtures`、`zig build dxil-source-bench -Doptimize=ReleaseSafe`，或用 `pwsh -NoProfile -File tests/dxil/run.ps1` 执行 Windows 官方校验与 GPU 回读，覆盖既有 10 个 shader 和 96 组 OpenGL 状态。脚本比较两个目标及 SM 6.9 两种绑定方式的布局、接口、像素与深度，为测试渲染器下载固定版本的 Agility SDK，完整验收需要 SM 6.9 硬件。核心无 DXC/LLVM 依赖；官方工具仅用于开发验收。通用 GLSL/真实包兼容、UBO/SSBO、sampler 数组、非一致资源索引和局部聚合对象动态写入仍不支持；详见[支持契约](docs/dxil.md#m2glsl-源码编译与反射)与 [SM 6.9 宿主要求](docs/dxil.md#m3sm-69-合法化与宿主要求)。

## 限制

第一阶段不支持 UBO/SSBO 块、几何/细分/计算着色器、函数重载、矩阵动态索引和图像原子操作等。完整列表见映射文档的“不支持的特性”一节。
