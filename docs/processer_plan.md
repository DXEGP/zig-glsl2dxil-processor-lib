# 方案 A：纯 Zig DXIL 后端，兼容 SM 6.5、面向 SM 6.9

## 1. 目标与约束

将外部 GLSL 逐步接入 DirectX 12，直接输出 DXIL。核心与发布运行时使用 Zig 0.17.0，不经 HLSL/SPIR-V，不链接 Mesa C、LLVM、Clang、DXC 或官方验证器。开发和 CI 允许官方工具作独立对照。

最低兼容 SM 6.5，设计目标 SM 6.9。首版分阶段覆盖明确的 VS/PS 子集，不承诺完整 GLSL 110–430、Minecraft/Iris 包兼容性或固定亚毫秒编译时间。现有 GLSL→HLSL API 保留。

方案 A 调整为“参考 Mesa/DXC 公开格式与实现，纯 Zig 按需实现后端”。原先直接抽离 Mesa C 的做法不符合纯 Zig 约束。方案 B 的前端单遍直发和方案 C 的字节码热拼接均不纳入本次实施，不保留未经验证的性能排名和代码量估算。

## 2. 已修正的技术边界

- LLVM 3.7 Bitcode 是 DXIL 的编码基础，但任意 LLVM IR 不等于合法 DXIL。
- 原生向量始于 DXIL 1.9；signature、cbuffer、typed buffer、texture 等不允许直接使用向量的位置仍须合法降级。
- `createHandleFromHeap` 始于 SM 6.6，另有资源绑定层级和 Root Signature 要求；SM 6.5 使用描述符表路径。
- validator 兼容版本 1.5 对应 PSV v1，1.9 对应 PSV v3，不能任意选择 v4。
- Cooperative Vector 不属于正式 DXIL 1.9 的必需能力。
- Retail Hash 是容器摘要，正确摘要不证明 IR、资源、元数据或实际执行正确。
- 全部内联与禁止所有 `alloca` 不是通用 DXIL 规范要求。首版可通过有限内联简化实现，后续保留可索引局部对象的合法存储。
- 宏条件不能自动等价改成运行时分支；CSE/提升必须尊重支配关系、资源访问及导数语义。
- `mat4` 的 float 数据为 64 字节；常量缓冲内部行布局、数组/矩阵步长与宿主 CBV 256 字节对齐应分别描述。
- `CreateGraphicsPipelineState` 的驱动工作独立计时，不能由前端指令数直接推导。

具体规范、固定版本与格式字段见 [DXIL 基线文档](docs/dxil.md)。

## 3. 目标架构

```text
源码 + 宏配置 + 内存 VFS
  → 预处理与源位置映射
  → 现有 Lexer / Parser / AST
  → 独立语义分析、类型检查与阶段接口分析
  → 类型化 SSA / CFG
  → 有限优化与目标合法化
  → Zig Bitcode 编码器
  → DXIL 容器、摘要、反射与功能要求
```

保留 AST，先从现有 HLSL emitter 抽出可共享的语义能力。Braun 算法用于 AST 到 SSA；短路、循环、提前返回及参数回写需有独立正确性测试。SIMD、取消 AST 和解析期间直接发射待基准证明收益后再考虑。

| 配置 | SM 6.5 | SM 6.9 |
| --- | --- | --- |
| DXIL / validator 兼容版本 | 1.5 / 1.5 | 1.9 / 1.9 |
| PSV | v1 | v3 |
| 向量 | 标量化 | 合法位置保留向量，其余降级 |
| 资源 | 描述符表、传统句柄 | 描述符表；满足能力要求时显式选择堆直接索引 |
| 当前状态 | M2 配对 GLSL 源码编译已实现 | M3 已实现并完成硬件对照 |

宿主显式选择目标并查询设备能力。反射返回完整名称、类型、偏移、大小、步长、绑定和功能要求；名称哈希不是唯一身份。纹理与采样器分别表示，不固定 20/12 位打包 ABI。

宿主负责 Root Signature、坐标/深度/正反面约定以及传统内置变量映射。独立阶段必须确定性分配签名；首版不做跨阶段死槽裁剪。资源句柄与 CBV 加载仅在可证明安全时复用或提升。

新增 DXIL API 返回二进制指针和长度，提供独立释放入口，不沿用文本结果语义。编译请求所需的 GLSL、VFS、资源契约接口随 M2 支持范围补齐；M1 公开低层程序发射接口。

## 4. 里程碑与验收

| 阶段 | 交付与门槛 | 状态 |
| --- | --- | --- |
| M0 | 固定规范/格式来源、工具和许可记录、支持矩阵、等价 HLSL 语料、独立校验工具 | 已落地，见 `tests/dxil/baseline.json` 与 `docs/dxil.md` |
| M1 | Zig Bitcode/容器/摘要、最小 VS/PS、二进制 Zig/C ABI；官方校验通过、零售模式 PSO 创建与像素回读、独立进程无编译 DLL | 已落地并在两种硬件适配器验证 |
| M2 | 独立语义层、SSA、算术/控制流/矩阵、uniform 布局/反射、描述符表采样、配置化 GL 状态 | 已实现，验收范围见下文 |
| M3 | SM 6.9 合法化、原生向量、可选堆直接索引；6.5/6.9 同程序对照 | 已实现，RTX 5070 完成三种配置硬件对照 |
| M4 | VFS/宏扩展、选定真实包适配、缓存、优化及可复现性能报告 | 未实施 |

### M0/M1 交付

- `src/dxil/`：位流、模块、PSV/签名/容器和 Retail Hash 的纯 Zig 实现。
- 程序接口：顶点 `POSITION0 float4` 透传为 `SV_Position`；片元输出参数化 RGBA 到 `SV_Target0`。
- C ABI：`glsl2hlsl_dxil_emit` / `glsl2hlsl_dxil_result_free`；二进制结果有独立所有权。
- `tests/dxil/`：参考源码和工具锁定清单、Zig 样例生成器、摘要边界对照、官方验证器、独立 D3D12 渲染器、无缓存基准与验收脚本。
- 生成的 Bitcode、容器、参考编译结果及验证日志位于被忽略的 `zig-out/dxil/`，无需提交生成二进制。
- M1 当时尚未接入 GLSL 前端；该能力现由 M2 单独提供，验收范围见下文。

### M2 交付与边界

- `sema.zig` 负责类型、完整函数检查、跨阶段链接与统一资源分配；`lower.zig` 使用 sealed-block SSA，覆盖短路、副作用、循环回边、提前返回和 out/inout 回写。
- `ir.zig` 验证类型、支配关系、PHI 前驱和签名/资源边界；`encode.zig` 编码一般指令，生成含控制依赖的 PSV/ViewID 信息。M1 程序也使用同一后端。
- `compileGraphics`、独立 C 图形结果 API 和 C++ RAII 包装提供 VS/PS 字节码、全名反射及阶段/文件/行列诊断。结果所有权明确，失败路径接受分配故障测试。
- uniform 按 DXIL cbuffer 行布局上传：vec3 后可紧接 float，数组行步长 16，矩阵列主序/列步长 16，结构体按行对齐；不宣称 std140 ABI 兼容。
- `GlCompat` 和宿主 helper 联合映射 clip origin/depth、正向/反向 depth range、viewport、正面绕序、非零 base instance，以及 FragCoord.y/w。默认 GL 模式，另提供显式 D3D12 native 模式。
- 10 份既有 shader 组成 8 个配对场景，另加一个原生基础场景。独立 GPU 测试覆盖非对称纹理/矩阵、MRT、discard、结构体和控制流；GL 状态矩阵为 2×2×3×2×2×2＝96 组，并补充裁剪、剔除和零/负 w。
- 官方 validator 必须原样接受源码产物并拒绝重算摘要后的签名损坏；GPU 在每个可用 SM 6.5 硬件适配器回读全部 16×16 像素，坐标场景另有独立 HLSL 参考。无硬件运行仅算部分验收。

首版不支持函数重载、sampler 数组、UBO/SSBO、动态局部写索引、导数、任意 GLSL 扩展和其他 shader 阶段；这些能力返回诊断。宏沿用现有前端子集，内存 VFS/include、真实包、缓存与性能优化属于 M4。

2026-11-02 实测：39 项库测试、静态/共享 C23 与 C++23/26、既有 10 个 HLSL 回归通过；74 个 M2 容器原样通过官方校验，损坏签名负例全部被拒绝。Intel UHD 和 NVIDIA RTX 5070 Laptop 各通过 127 个 16×16 回读场景，独立 HLSL 坐标对照也通过；发布 DLL 和渲染进程没有编译器依赖。详情与重跑日志见 `docs/dxil.md` 和 `zig-out/dxil/report.json`。

### M3 交付与边界

- `target.zig` 集中定义 SM 6.5/6.9、功能要求和合法化；6.9 使用 DXIL/validator 1.9、PSV v3，把旧句柄转换为 `createHandleFromBinding` + `annotateHandle`。
- 2/3/4 分量 float/int/uint 算术保留原生向量；signature、cbuffer、纹理边界继续标量化，PSV/ViewID 按 lane 传播依赖。矩阵、比较与内置函数沿用支持的标量实现。
- 默认描述符表；显式直接堆使用真实 `createHandleFromHeap`，反射返回绝对堆槽与 SM/Tier/根签名要求。旧 C 请求/结果结构不扩容，扩展请求与执行信息 getter 提供新能力。
- 硬件宿主按要求检查 SM 6.9、资源绑定 Tier 3、根签名 1.1，先设置描述符堆再设置根签名；固定 Agility SDK 仅用于测试渲染器，发布编译库保持纯 Zig。
- 同源码三种配置比较完整资源/结构体布局、阶段接口及全部像素/深度；新增非对称浮点/整数向量场景、越界堆与非法 IR 负例、三种配置分配故障检查。

2026-11-02：M2 的 80 个容器及 M3 的 100 个容器原样通过官方验证，签名负例全部被拒绝。RTX 5070 Laptop 通过 6.5 表/6.9 表/6.9 堆各 128 个 16×16 场景，像素与深度一致；Intel UHD 最高 SM 6.7，保留 6.5 回归并显式跳过 6.9。非一致资源索引、sampler 数组、任意局部动态写入和更广 GLSL 支持未纳入本阶段。协议与证据见 `docs/dxil.md`、`zig-out/dxil/report.json`。

### 下一阶段顺序

1. 使用 `tests/dxil/run.ps1` 持续重放 M1/M2；先固定语义回归，再优化，禁止以 validator 通过代替 GPU 结果。
2. 持续运行 M3 三种配置的同源码资源、接口和硬件回读对照；不能用版本/validator 通过代替原生向量指令与 GPU 验收。
3. M4 单独设计 VFS/宏配置、资源上限、缓存键及真实包支持清单。对预处理、语义、SSA、编码、内存峰值与 PSO 分别测量，依据剖析结果决定优化。

### 验证命令

```powershell
zig build test dxil-c-test
zig build dxil-fixtures -Doptimize=ReleaseSafe
zig build dxil-bench -Doptimize=ReleaseSafe
zig build dxil-source-fixtures dxil-source-bench -Doptimize=ReleaseSafe
pwsh -NoProfile -File tests/dxil/run.ps1
```

完整验收必须运行硬件测试；`-SkipHardware` 只产生部分验收结果。完整脚本要求 Developer Mode 未启用且 D3D12 调试层可用，比较两组不同 RGBA 的全部 4×4 像素。官方验证器必须保持生成字节完全不变，并拒绝故意损坏的输出签名。

2026-11-02：Zig 0.17.0、DXC/validator 1.9.0.5512，Intel UHD 与 NVIDIA RTX 5070 Laptop 均通过最小程序渲染，独立渲染进程没有 `dxcompiler.dll`/`dxil.dll`。工具/驱动、源码来源、摘要、样例 SHA256 及重跑方法见 DXIL 基线文档与脚本报告。

## 5. 性能与后续质量门槛

无缓存基准分别报告首次生成、P50/P95/P99 和产物大小；M1 仅测 Bitcode/容器发射，不含 GLSL、SSA、官方验证或 GPU 工作。PSO 时间单列，记录驱动缓存影响。后续再按预处理 Token 规模分层测试真实语料、内存峰值及 GPU 执行时间。

`0.1–0.8 ms` 只作为小型着色器热编译的待验证目标，不包含 PSO/驱动编译。缓存命中不得替代真实编译耗时。

M2 已加入循环回边/短路副作用/参数回写、非对称矩阵、uniform 行边界/步长、flat 接口、MRT 和坐标转换回归。非一致资源索引、VFS/include 和扩展浮点语义仍须按后续能力增加验收；无法支持的能力必须返回诊断，不能静默改语义或转用外部编译器。
