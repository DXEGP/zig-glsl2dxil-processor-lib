# DXIL 后端：M0–M3 源码编译与验收

本页记录方案 A 的 M0/M1 基线、M2 配对 GLSL 编译及 M3 双目标后端。核心实现使用 Zig 0.17.0，支持 SM 6.5 / DXIL 1.5 与 SM 6.9 / DXIL 1.9。M1 低层程序接口和原有 GLSL→HLSL 接口继续可用。

## M0：固定参考与支持矩阵

规范和工具清单保存在 [`tests/dxil/baseline.json`](../tests/dxil/baseline.json)。源码引用固定到提交，不依赖上游分支后续变化；格式相关文件同时记录 SHA256。

| 参考库 | 固定提交 | 用途 |
| --- | --- | --- |
| [DirectXShaderCompiler](https://github.com/microsoft/DirectXShaderCompiler/tree/f9fc72ad3fd796227400ef6f52097968f843f7ee) | `f9fc72ad3fd796227400ef6f52097968f843f7ee` | LLVM 3.7 Bitcode、DXIL、签名、PSV、摘要格式 |
| [hlsl-specs](https://github.com/microsoft/hlsl-specs/tree/9a8866f45599457900876fba0d02caf3a1e8544c) | `9a8866f45599457900876fba0d02caf3a1e8544c` | 0030 原生向量、0033 DXIL 1.9 的后续兼容边界 |
| [DirectX-Specs](https://github.com/microsoft/DirectX-Specs/tree/d5f41d531fdcce7fac624d2a619ba1e980e5163e) | `d5f41d531fdcce7fac624d2a619ba1e980e5163e` | SM 6.5/6.9、SM 6.6 描述符堆直接索引约束 |

| 能力 | M1 已实现 | 后续边界 |
| --- | --- | --- |
| 程序输入 | `vertex_passthrough`、`fragment_constant: [4]f32` | GLSL 语义分析和 SSA 属于 M2 |
| 目标 | SM 6.5、DXIL 1.5、validator 兼容版本 1.5、PSV v1 | M3 增加 SM 6.9 / DXIL 1.9 / PSV v3 |
| 顶点接口 | `POSITION0: float4` → `SV_Position: float4` | 尚无任意用户 signature、跨阶段链接 |
| 片元接口 | 无输入；`SV_Target0: float4` | 尚无纹理、uniform、MRT、discard |
| 控制流与计算 | 单基本块、loadInput/storeOutput、常量 | 尚无一般算术、用户函数和循环 |
| 外部依赖 | 编译器核心仅 Zig 标准库；不加载编译 DLL | DXC/C++/Windows SDK 仅用于开发验收 |
| 容器 | `SFI0`、`ISG1`、`OSG1`、`PSV0`、`DXIL` | Root Signature 由宿主创建 |

SM 6.5 路径后续使用描述符表，不发射 SM 6.6 才支持的 `createHandleFromHeap`。SM 6.9 的原生向量仅在规范允许的位置保留，signature、cbuffer 和纹理边界仍需降级。不能通过只改版本号获得 6.9 支持。

### 来源与许可证

`src/dxil/` 为本项目编写的 Zig 实现；M1 没有引入 Mesa 或 DXC 的 C/C++ 实现。Bitcode 记录编号、容器字段和摘要规则依据上述公开实现；Retail Hash 的 MD5 压缩使用 Zig 标准库，最后块使用 DXC 的 Retail 填充规则。

仓库许可证为 GPLv3。DXC 格式/摘要参考文件声明 University of Illinois/NCSA 许可证，完整条件见固定版本的 [LICENSE.TXT](https://github.com/microsoft/DirectXShaderCompiler/blob/f9fc72ad3fd796227400ef6f52097968f843f7ee/LICENSE.TXT)。来源声明和适用许可随附于 [dxil-reference-license.txt](dxil-reference-license.txt)，构建时安装到 `share/glsl2hlsl/`。开发脚本仅在被忽略的 `.zig-cache/dxil-reference/` 下载原始 `DxilHash.cpp`，保留其原有声明并核对 SHA256；不安装或分发它及其测试程序。若以后移植、分发其他上游代码，需按原文件许可证保留声明和随附许可文本。当前未依赖 Mesa 的任何许可授权。

## M1：编码、容器与摘要

`src/dxil/bitstream.zig` 写入低位优先位流、VBR、32 位对齐、嵌套块长度和未缩写记录。`module.zig` 将 M1 程序构造为一般 IR，`encode.zig` 生成类型表、属性、函数声明、常量、元数据、符号表及函数体，输出真实 LLVM 3.7 Bitcode；不读取或拼接预编译 DXIL。

`container.zig` 生成各 Part 和偏移表，设置 SM/DXIL 版本，再用 `hash.zig` 计算从容器偏移 `0x14` 到末尾的 Retail 摘要并回填 `0x04`。这是格式摘要，不能替代官方语义验证。validator 1.5 的签名 Part 保留实际字符串长度；1.9 对名称按内容去重并补齐到 4 字节。

| 字段 | M1 值 |
| --- | --- |
| `dx.version` / `dx.valver` | `{1, 5}` |
| `dx.shaderModel` | `vs/ps, 6, 5` |
| Bitcode 模块版本 | 1，相对值编号 |
| PSV RuntimeInfo 长度 | 36 字节，PSV v1 |
| SFI0 | 0，没有请求可选功能 |
| 资源 / Root Signature Part | 无；测试宿主创建允许 Input Assembler 的空根签名 |

`validate` 只检查容器长度、偏移、重叠和摘要；`getPart` 在此基础上查找 Part。两者不是 DXIL 语义验证器。

### Zig 接口

从 `processor.dxil` 使用 `emit(allocator, program, target)`。成功返回拥有所有权的 `[]u8`，调用方以相同 allocator 释放；输出不是以零结尾的文本。错误包括 `OutOfMemory` 和 `UnsupportedTarget`。

```zig
const bytes = try processor.dxil.emit(allocator, .{
    .fragment_constant = .{ 0.25, 0.5, 0.75, 1.0 },
}, .sm65);
defer allocator.free(bytes);
```

### C ABI

`glsl2hlsl_dxil_emit` 接受 `glsl2hlsl_dxil_options`，包括程序种类、目标 SM 和 RGBA；顶点透传忽略 RGBA。成功返回独立的 `uint8_t*` 和字节长度。调用方用 `glsl2hlsl_dxil_result_free` 释放；释放后归零，可重复释放和传空指针。重复使用结果结构前必须先释放已有结果。

M1 发射接口接受 SM 6.5 和 SM 6.9。未知目标/程序枚举或空参数返回 `INVALID_ARGUMENT`。失败不返回字节码。原有状态值和文本 API 的 ABI 保持不变；`UNSUPPORTED_TARGET` 为 4。M1 不增加 C++ 专用包装，C++23/26 可直接使用 C ABI。

## 构建与验收

```powershell
zig build test dxil-c-test
zig build dxil-fixtures -Doptimize=ReleaseSafe
zig build dxil-bench -Doptimize=ReleaseSafe
pwsh -NoProfile -File tests/dxil/run.ps1
```

`dxil-fixtures` 在 `zig-out/dxil/` 输出透传 VS、两组不同常量的 PS 和摘要边界用例。可用 `-Ddxil-output=<directory>` 改变样例输出目录。所有样例均为本次 Zig 生成。

完整验收需要 Windows、支持 SM 6.5 的硬件适配器、Windows Graphics Tools 调试层、DXC 及其 `dxcapi.h`。脚本从 `DXC` 或 PATH 查找 DXC；也可传 `-Dxc` 和 `-DxcInclude`。第一次摘要对照需联网下载固定来源，之后可离线使用已验证的缓存。

脚本执行以下检查，任一失败均返回非零退出码：

1. Zig 单元测试、分配失败清理测试和 C23 二进制 ABI 测试。
2. 14 个摘要长度用例与固定 DXC `ComputeHashRetail` 实现对照，覆盖 55/56、63/64、119/120 等填充边界。
3. 三个 Zig 生成的容器经官方 `IDxcValidator` 校验，并比较返回容器逐字节相同；故意损坏输出签名的负例必须被拒绝。
4. DXC 生成等价 HLSL 参考样例；输出反汇编供人工检查。
5. 检查 Windows Developer Mode 未启用；脚本不修改系统设置。
6. 独立渲染进程逐个测试支持 SM 6.5 的硬件适配器。创建 PSO，绘制覆盖 4×4 浮点 RT 的三角形，回读全部像素的两个 RGBA 结果，绝对误差不超过 `1e-6`；同时检查 D3D12 调试层错误。
7. 参考 DXC 着色器执行相同回读断言。渲染进程在 PSO 创建后及执行后确认未加载 `dxcompiler.dll`、`dxil.dll`。另外构建发布 DLL 并检查它和渲染器的 PE 导入表，拒绝 DXC、DXIL 验证器、LLVM、Clang 或 Mesa 依赖。

`-SkipHardware` 仅用于无 GPU 的开发机，报告明确标记 M1 验收不完整；不能用该结果宣布 M1 完成。工具版本、驱动、样例 SHA256、开发者模式及测试结果写入 `zig-out/dxil/report.json`，详细日志位于同目录。版本变化会被记录，不会冒充初始基线。

## 基准与已验证结果

`dxil-bench` 对每种最小程序执行首次生成及 1001 次无缓存生成，计入内部分配、Bitcode、容器和摘要，排除文件 I/O 与调用方释放。报告首次耗时与 P50/P95/P99；首次为进程内该程序第一次调用，不代表冷磁盘/冷 OS。它不测 GLSL 解析、SSA、GPU 执行或峰值内存，也不为完整编译性能提供证据。PSO 时间由渲染日志单独记录，可能受驱动缓存影响。

2026-11-02 的初始实测环境：Windows build 26300、Zig 0.17.0、DXC/validator 1.9.0.5512（`01b62ad47`），Developer Mode 注册表未启用，调试层可用。Intel UHD（驱动 `32.0.101.7092`）与 NVIDIA RTX 5070 Laptop（`32.0.16.2101`）均通过两组像素回读；渲染进程未加载编译/验证 DLL。生成 VS 为 1257 字节，两个 PS 各为 1030 字节；原始实测日志由重跑脚本生成，耗时不设通过阈值。

| 初始验收项 | 结果 |
| --- | --- |
| Zig 库单元测试 | 29/29，包括容器错误输入、确定性输出、分配失败和 C ABI |
| C ABI 链接 | 静态库与共享库的 `dxil-c-test` 均通过 |
| 官方摘要对照 | 14/14 长度边界用例通过；另有 3 个固定已知答案 |
| 官方完整容器校验 | 3/3 原样通过；3/3 正确重算摘要的损坏签名负例被拒绝 |
| GPU 回读 | 2 个硬件适配器，各 2 组 RGBA、每组全部 16 像素通过；调试层无错误 |
| DLL 导入 | 核心 DLL 仅 `ntdll.dll`、`KERNEL32.dll`；渲染进程无编译 DLL |
| 既有回归 | C23、C++23、C++26 与 10 个 GLSL/HLSL shader 回归通过 |
| 格式和文档 | `zig fmt --check`、diff 空白检查、文档文件链接检查通过 |

首次完整报告中的无缓存 P50/P95/P99：VS 为 22.5/31.8/38.8 微秒，PS 为 19.1/26.8/33.7 微秒。这些数值只用于最小程序发射基线，不能外推完整 GLSL 编译性能。生成物 SHA256：

- VS：`F0AFD3C1368580D1F55DEA734AE6E4E399FB28CDCFB9937460C5ACA0640857AD`。
- PS：`B24DFDAC79A575A3FBACC9F0EC4BB4424C1F68CE3BF9D87273C2D477F5D2FAAD`。
- 替代 RGBA PS：`C57241254D2DE3A919BE64752E6ACE6A8FFFA3C9BE0F0093A2102EAA90B9BA90`。

以上数字和 SHA256 是原始 M1 历史基线；M2 已更换共用 IR/编码器，当前产物、耗时及验证结果以重跑报告为准。

## M2：GLSL 源码编译与反射

`graphics.zig` 接收配对 VS/PS。前端仍使用现有预处理、Lexer、Parser 和 AST；`sema.zig` 独立分析声明、类型、完整函数、接口和 uniform；`lower.zig` 用 sealed-block 算法生成标量 SSA/CFG；`ir.zig` 检查类型、支配关系、PHI、签名与资源边界。`encode.zig` 计算数据与保守控制依赖，生成 Bitcode、资源元数据及 PSV/ViewID 信息。

### 支持契约

| 类别 | M2 支持 |
| --- | --- |
| 阶段/接口 | 配对 VS/PS；float/int/uint 标量与向量；显式 location 或按名链接；smooth/flat/noperspective；最多 8 个 MRT；FragDepth |
| 计算 | 32 位数值、bool、向量/矩阵构造、浮点矩阵乘法、swizzle、固定局部索引、动态只读聚合索引 |
| 控制流 | if、短路、同型 ternary、for/while/do、switch/fallthrough、break/continue、提前返回、有限内联、out/inout 回写 |
| 资源 | 默认 uniform/结构体/数组/列主序矩阵；sampler2D、texture/texture2D、textureLod、texelFetch；传统 createHandle |
| 内置变量 | Position、VertexID、InstanceID、FragCoord、FrontFacing、FragDepth、旧版 FragColor |
| 限制 | 单阶段源码 1 MiB、262144 token、语法/表达式嵌套计数上限 256、结构体深度 64、4096 基本块、内联深度 32、单个局部聚合最多 16384 分量、Globals 最大 64 KiB |

函数重载、递归、重叠 out/inout 写回、sampler 数组、非一致资源索引、动态局部写索引、UBO/SSBO、其他纹理种类、导数、double 和其他 shader 阶段尚不支持。预处理沿用现有子集，不增加 include/VFS。宏展开保持行号，诊断列是展开后 token 位置；不提供宏调用栈或 `#line` 文件重映射。浮点算术不设置 fast-math；未承诺跨设备逐位浮点一致性。

### Zig 与 C/C++ 所有权

```zig
var diagnostics_arena = std.heap.ArenaAllocator.init(allocator);
defer diagnostics_arena.deinit();
var diagnostics = processor.diag.Diagnostics.init(diagnostics_arena.allocator());
var result = try processor.compileGraphics(allocator, .{
    .vertex = .{ .source = vertex_source, .name = "shader.vert" },
    .fragment = .{ .source = fragment_source, .name = "shader.frag" },
    .coordinates = .opengl,
}, &diagnostics);
defer result.deinit();
```

结果 arena 拥有字节码和反射；所有视图在 `deinit` 后失效。诊断使用独立的调用方 allocator，失败后仍可读取。可选 `GraphicsRequest.measurement` 接受带 `std.Io` 的 `Measurement`，记录前端、语义检查、lower 和编码耗时；默认不读取时钟。

C 使用 `glsl2hlsl_dxil_graphics_options`，设置 `shader_model=GLSL2HLSL_SM_6_5` 或 `GLSL2HLSL_SM_6_9`。源码/名称是借用的指针与长度，函数返回后可释放。空指针配非零长度、无效枚举或空输出参数返回 INVALID_ARGUMENT；SM 6.5 请求堆直接索引返回 UNSUPPORTED_TARGET；编译诊断返回 INVALID_SHADER。

`glsl2hlsl_dxil_graphics_result` 的 owner 拥有两份二进制、反射、以零结尾的名字和诊断消息；也返回显式长度。失败时仅保留诊断，不返回部分字节码/反射。用 `glsl2hlsl_dxil_graphics_result_free` 释放，它支持空指针及重复释放并归零结果；重复编译到同一结果前先释放。不可复制 owner 后分别释放。C++ `compile_graphics`/`GraphicsResult` 自动执行这一协议，支持 noexcept 移动，禁止复制；参见 [C++ 文档](cpp-api.md#dxil-配对源码接口)。

### 反射与宿主绑定

schema 版本为 1。顶层 uniform、结构体成员全名、类型、偏移、大小、数组/矩阵步长、结构体字段，以及阶段可见性均可查询；stages 位 0 表示 VS，位 1 表示 PS。`structure_index` 仅在 scalar 为 STRUCT 时有效；结构体字段 offset 相对其结构体起点，uniform offset 相对 Globals。结构体数组使用顶层 array_stride 和结构体字段元数据逐层寻址。

名称按字节序排序后分配统一绑定：Globals 为 `b0,space0`；GL 模式 GlCompat 为 `b0,space1`；sampler2D 分拆成同编号 `tN/sN,space0`。显式 sampler binding 优先，其他资源填空位。反射同时包含 VS/PS 实际需要的绑定，宿主创建描述符表、CBV 和 Root Signature；不嵌入 Root Signature Part。

uniform 使用 DXIL cbuffer 行布局，不能直接上传 std140 内存：vec3 后的 float 可共享一行；数组元素与结构体起点按 16 字节行对齐；矩阵按列存放，每列 16 字节。CBV 分配/大小另外按 D3D12 的 256 字节要求对齐。按反射上传，不把名称哈希当唯一身份。

用户顶点属性使用 `TEXCOORD<location>`；VS/PS varyings 经联合链接分配相同硬件 row，SV_Position 保留 row 0。签名反射的 name 是 D3D 语义名称，semantic_index 是语义下标，row 是硬件行，不能混用。fragment 输出最多 SV_Target0..7；整数 varying 必须 flat。

### OpenGL 状态契约

默认编译模式是 OpenGL。宿主每次相关状态变化时调用 `glsl2hlsl_dxil_prepare_gl_state`，并同时：

1. 将 constants 的 32 字节原样上传到反射的 GlCompat。
2. 将 viewport 六项按 x/y/width/height/MinDepth/MaxDepth 设置到 D3D12。
3. 将 front_counter_clockwise 用于 rasterizer/PSO 的 FrontCounterClockwise。
4. 将 start_instance_location 传给 DrawInstanced/DrawIndexedInstanced 的 StartInstanceLocation。

origin 枚举为 LOWER_LEFT/UPPER_LEFT，depth 为 NEGATIVE_ONE_TO_ONE/ZERO_TO_ONE，winding 为 CCW/CW。state.viewport_y 使用 GL 窗口下边起算的 viewport，target_height 是渲染目标高度。当前 helper 要求有限、正尺寸、非负 viewport 起点且 y 范围位于目标内，depth_near/far 位于 [0,1]；不合法状态清零输出并返回 INVALID_ARGUMENT。

VS 根据 clip origin 翻转 y，并将 z 转为 D3D 的 [0,w] 裁剪体积。反向 depth range 通过反转 clip z 配合排序后的 D3D MinDepth/MaxDepth 保持裁剪与深度映射；viewport.top=target_height-y-height。PS 将 FragCoord.y 转回 GL 窗口坐标，将 D3D SV_Position.w 取倒数得到 GL 的 1/clip.w，保留窗口深度。FrontFacing 由 helper 的绕序映射实现；不依赖宿主额外翻转。

base_instance 仅用于宿主起始实例，GlCompat 第五个 word 为 0；SM 6.5 SV_InstanceID 是本次 draw 的实例索引，GL InstanceID 不包含 base instance。非零值必须作为 Draw 参数传入，不能再从内置值减去 base instance。实例属性和索引绘制的 base vertex 仍由宿主 Input Assembler/Draw 参数管理。

上述 GL 规则依据固定的 [ARB_clip_control](https://github.com/KhronosGroup/OpenGL-Registry/blob/1f8f4efc1d610052492e1099690822c68e4efb20/extensions/ARB/ARB_clip_control.txt)、OpenGL 4.6 Core §13.5/13.6/14.6 以及 GLSL 4.60 的 FragCoord/InstanceID 定义。这里不实现 ARB_fragment_coord_conventions 的显式 origin_upper_left/pixel_center_integer 重声明。显式选择 d3d12_native 时不创建 GlCompat、不插入 GL 转换，宿主直接遵循 D3D12 内置语义。

### M2 验收与性能

`zig build dxil-source-fixtures` 输出既有 10 个 shader 的 8 个配对场景、native 基础场景和向量场景，每种目标/绑定配置共 20 个容器及 JSON 反射。`tests/dxil/source_render.cpp` 通过公开 C ABI 现场编译，按反射绑定资源；每个硬件适配器逐像素检查 16×16 浮点 RT 和相关深度值，包括两张非对称纹理、显式 mip、MRT、discard、结构体分支、非对称矩阵、循环/短路/提前返回/回写。

GL 验收矩阵为 2 origins × 2 clip depths × 3 depth ranges × 2 windings × 2 base instances × 2 viewports＝96 组；另测裁剪体积外、正面剔除、零/负 w。CPU 公式提供期望值，独立 HLSL 坐标程序经 DXC 编译后重复相同断言。每个渲染进程都检查调试层错误和编译 DLL 缺席。完整 `run.ps1` 同时保留 M1 验收，官方 validator 原样检查全部新产物并拒绝损坏签名；报告将硬件跳过明确标记为未完成。

`zig build dxil-source-bench -Doptimize=ReleaseSafe` 对 triangle/showcase 分别测首次和 101 次无缓存配对编译，报告总时间 P50/P95/P99、各阶段 P50、请求内存峰值及产物大小。计数 allocator 禁用原地 resize/remap，峰值反映该分配策略，不等同进程 RSS。读取源码在计时外，释放、文件 I/O、官方验证和 PSO 不计入编译时间；不设置亚毫秒门槛。M2 的通过不代表完整 GLSL 或 Minecraft/Iris 包已可用；M3 验收单独记录。

2026-11-02 的 M2 验收使用上述 DXC/validator 和两块硬件，Developer Mode 关闭、调试层开启：

| 验收项 | 结果 |
| --- | --- |
| 库单元测试 | 39/39，包括分配失败清理、源位置、未调用函数及嵌套上限 |
| C/C++ | 静态和共享 C23、C++23、C++26 测试通过 |
| 原有 HLSL 路径 | 10 个源码转换并经 DXC 编译通过 |
| M2 官方验证 | 74 个容器逐字节原样通过；74 个损坏签名负例均被拒绝，包含 GPU 进程生成的额外语义场景 |
| 硬件回读 | Intel UHD 与 NVIDIA RTX 5070 Laptop 各 127 场景，共 254 次，每次比较全部 256 像素；独立 HLSL 坐标参考再执行相同矩阵 |
| 运行时依赖 | 发布 DLL 仅导入 ntdll/KERNEL32；两种渲染器未加载编译/验证 DLL |
| 无缓存源码基准 | triangle/showcase 配对 P50 为 0.1923/0.2585 ms，请求内存峰值 346520/551746 字节；仅代表本次机器和语料 |

重跑报告为 `zig-out/dxil/report.json`，明细日志为 `source-validation.txt`、`source-render.txt`、`reference-source-render.txt` 和 `source-benchmark.txt`。生成物随适配器数量与语料增加而变化，不能把 74 当固定覆盖率要求。

## M3：SM 6.9 合法化与宿主要求

`target.zig` 集中管理目标与执行要求。SM 6.5 保持标量化与传统 `createHandle`；SM 6.9 使用 DXIL/validator 1.9、PSV v3（52 字节 RuntimeInfo、24 字节资源记录、入口名称），把描述符表句柄改写为 `createHandleFromBinding` + `annotateHandle`。`SFI0` 与入口 shader flags 按实际使用的堆生成，默认描述符表不会要求直接索引标志。

GLSL 的 2/3/4 分量 float/int/uint 向量算术在 SM 6.9 中生成原生向量二元指令；矩阵乘法、比较、转换和现有内置函数继续使用已支持的标量实现。LLVM insertelement/extractelement 连接内部向量和标量边界；signature、cbuffer、纹理参数与返回值保持标量接口，不能把向量传入不支持的 DXIL 重载。PSV/ViewID 分析逐分量传播依赖，避免将一个向量的所有输入误记为每个输出的依赖。SM 6.5 入口拒绝外部构造的原生向量 IR；GLSL 前端根据目标选择合法表示。

### 显式堆布局与 ABI

Zig 请求设置 `.target = .sm69`、`.binding_mode = .direct_heap`，可用 `.heap_layout = .{ .resource_base = 3, .sampler_base = 5 }` 预留宿主槽位。默认仍为 `.descriptor_tables`。C 旧 options/result 结构大小不变；新入口 `glsl2hlsl_dxil_compile_graphics_ex` 接受 `glsl2hlsl_dxil_graphics_options_ex`，必须设置 `struct_size = sizeof(options)`，并填入原有 `base` 请求。SM 6.5 的堆请求返回 UNSUPPORTED_TARGET；非法扩展大小/枚举返回 INVALID_ARGUMENT；堆槽越界返回带诊断的 INVALID_SHADER。

`glsl2hlsl_dxil_graphics_execution_info` / C++ `execution_info()` 返回目标、DXIL/validator 版本（十进制 19 表示 1.9）、PSV 版本、原生向量使用情况、feature flags、最小资源绑定层级、根签名版本（10/11）、根标志以及堆映射。info 是值拷贝，内部 `heap_bindings` 是结果拥有的借用数组，释放结果后失效；getter 拒绝失败或已释放的结果。

堆映射的 `binding_index` 指向原反射 binding 数组，`heap_index` 是选定堆的绝对槽位。CBV 和 SRV 按反射顺序共用资源堆，sampler 使用独立堆；每个绑定占一槽，VS/PS 共用同一分配。资源堆最多 1,000,000 槽、sampler 堆最多 2,048 槽，基址和实际槽位均受此约束。反射的完整资源名、寄存器、space、uniform 布局和阶段接口与 SM 6.5 相同；直接堆产物不声明描述符表范围。

本阶段支持编译时分配的统一堆索引，不增加运行时索引表达式、sampler 数组或非一致资源访问。实际访问生成 `createHandleFromHeap` + `annotateHandle`。

### 宿主设置顺序

1. 用 `CheckFeatureSupport(SHADER_MODEL)` 确认 SM 6.9；原生向量不需要额外设备开关。堆模式还要求 ResourceBindingTier 3 和 Root Signature 1.1。离线编译 API 不查询设备，不会自动降级目标。
2. 创建 shader-visible CBV/SRV/UAV 与 sampler 堆，按反射绝对槽位写描述符。CBV 的资源地址/大小仍按 256 字节对齐。
3. 用执行要求的 `root_flags` 创建 Root Signature：资源堆标志 `0x400`、sampler 堆标志 `0x800`，按实际阶段用量取并集。堆模式不需要为这些资源创建 root 参数或描述符表。
4. 录制命令时先 `SetDescriptorHeaps`，再 `SetGraphicsRootSignature`，然后 Draw。直接索引要求此顺序；更换堆后重新设置根签名。继续使用反射及 GL helper 上传 Globals/GlCompat。

### 验收与工具

`tests/dxil/run.ps1` 从 NuGet 下载固定 Microsoft.Direct3D.D3D12 1.620.1，核对 `baseline.json` 中 SHA256，仅在 `zig-out/dxil/agility/` 部署测试渲染器需要的 D3D12Core/SDKLayers。下载包缓存保留于 `.zig-cache/dxil-reference/`。Agility SDK 属于测试宿主的 D3D12 运行时，未链接进发布编译库；其许可证以下载包内条款为准，生成 DLL 不提交。默认手动编译渲染器使用系统运行时；传 `-DGLSL2HLSL_TEST_AGILITY=620` 才启用对应测试 DLL。

完整脚本先执行 M1/M2，再以 `--m3` 在每个支持 SM 6.9 的硬件适配器运行相同源码的三种配置：6.5 描述符表、6.9 描述符表、6.9 直接堆。比较全部资源/结构体布局和接口，并保留 6.5 实际回读值，对比 6.9 全部像素及深度；同时保留独立 CPU 与 HLSL 坐标断言。专用向量场景验证 2/3/4 分量、浮点除法、整数移位/XOR 和非对称 lane；反汇编必须包含真实向量指令。

2026-11-02 完整实测：M2 的 80 个容器与 M3 的 100 个容器原样通过官方 validator，重算摘要的签名损坏负例全部被拒绝。RTX 5070 Laptop 通过三种配置各 128 个 16×16 场景（含 96 组 GL 状态），资源、接口、像素、深度一致；Intel UHD 通过 128 个 SM 6.5 场景，设备最高 SM 6.7，明确跳过 6.9。发布 DLL 和渲染进程无编译/验证 DLL 依赖。没有 SM 6.9 硬件时完整脚本失败，`-SkipHardware` 标为部分验收。

重跑入口为 `pwsh -NoProfile -File tests/dxil/run.ps1`；M3 结果位于 `report.json` 的 `m3` 字段、`m3-validation.txt`、`m3-render.txt` 和 `m3/vectors.frag.dxil.ll`。额外输出目录 `m3-heap/` 保存堆模式产物；与 `m2/`、`m3/` 的反射逐份比较。测试目录和文件数量随覆盖扩大而变化。
