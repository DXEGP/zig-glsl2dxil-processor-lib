# C / C++ 接口

转换器现在以库为主要构建产物，同时提供 C ABI 和头文件式的 C++23 封装。

## 语言标准

- C 头文件要求 C23（`__STDC_VERSION__ >= 202311L`）。
- C++ 封装要求 C++23（`__cplusplus >= 202302L`），并已用 C++26 验证。
- 使用更低的标准会在包含头文件时触发 `#error`。

## 构建产物

```powershell
zig build -Doptimize=ReleaseSafe
```

默认生成静态库：

| 路径 | 内容 |
| --- | --- |
| `zig-out\lib\glsl2hlsl.lib` | 静态库 |
| `zig-out\include\glsl2hlsl\glsl2hlsl.h` | C 头文件 |
| `zig-out\include\glsl2hlsl\glsl2hlsl.hpp` | C++ 头文件 |

生成动态库：

```powershell
zig build -Dshared=true -Doptimize=ReleaseSafe
```

| 路径 | 内容 |
| --- | --- |
| `zig-out\bin\glsl2hlsl.dll` | 动态库 |
| `zig-out\lib\glsl2hlsl.lib` | 导入库 |
| `zig-out\include\glsl2hlsl\` | 头文件 |

需要命令行工具时显式开启：

```powershell
zig build -Dcli=true -Doptimize=ReleaseSafe
```

可执行文件位于 `zig-out\bin\glsl2hlsl.exe`，用法见 [usage.md](usage.md)。

## C ABI

头文件同时兼容 C23 和 C++23。

### 类型

```c
typedef enum glsl2hlsl_stage {
    GLSL2HLSL_STAGE_AUTO = 0,
    GLSL2HLSL_STAGE_VERTEX = 1,
    GLSL2HLSL_STAGE_FRAGMENT = 2
} glsl2hlsl_stage;

typedef enum glsl2hlsl_status {
    GLSL2HLSL_STATUS_OK = 0,
    GLSL2HLSL_STATUS_INVALID_SHADER = 1,
    GLSL2HLSL_STATUS_OUT_OF_MEMORY = 2,
    GLSL2HLSL_STATUS_INVALID_ARGUMENT = 3
} glsl2hlsl_status;

typedef enum glsl2hlsl_severity {
    GLSL2HLSL_SEVERITY_ERROR = 0,
    GLSL2HLSL_SEVERITY_WARNING = 1
} glsl2hlsl_severity;
```

`GLSL2HLSL_STAGE_AUTO` 使用与命令行相同的阶段推断规则。

诊断项：

```c
typedef struct glsl2hlsl_diagnostic {
    glsl2hlsl_severity severity;
    uint32_t line;
    uint32_t column;
    char *message;
    size_t message_length;
} glsl2hlsl_diagnostic;
```

转换结果：

```c
typedef struct glsl2hlsl_result {
    glsl2hlsl_status status;
    char *output;
    size_t output_length;
    glsl2hlsl_diagnostic *diagnostics;
    size_t diagnostic_count;
} glsl2hlsl_result;
```

### 函数

```c
[[nodiscard]] glsl2hlsl_status glsl2hlsl_convert(
    const char *source,
    size_t source_length,
    glsl2hlsl_stage stage,
    glsl2hlsl_result *result);

void glsl2hlsl_result_free(glsl2hlsl_result *result);

const char *glsl2hlsl_version(void);
```

`glsl2hlsl_convert` 的行为：

- `source` 不必以 NUL 结尾，长度由 `source_length` 指定，可以处理空着色器。
- `result` 必须指向可写结构体；函数会覆盖其全部字段。
- 成功时返回 `GLSL2HLSL_STATUS_OK`，`output` 为生成的 HLSL；`diagnostics` 可能包含警告。
- 着色器或转换错误时返回 `GLSL2HLSL_STATUS_INVALID_SHADER`，`diagnostics` 至少包含一条错误。
- 参数非法时返回 `GLSL2HLSL_STATUS_INVALID_ARGUMENT`，此时不分配内存。
- 内存不足时返回 `GLSL2HLSL_STATUS_OUT_OF_MEMORY`。

### 所有权

`output`、`diagnostics` 数组以及每条诊断的 `message` 都由库分配。调用方不得用 `free()`、`delete` 或自己的分配器释放，必须在不再使用时调用一次 `glsl2hlsl_result_free`：

```c
glsl2hlsl_result result = {};
glsl2hlsl_status status = glsl2hlsl_convert(source, strlen(source), GLSL2HLSL_STAGE_FRAGMENT, &result);

if (status == GLSL2HLSL_STATUS_OK) {
    fwrite(result.output, 1, result.output_length, stdout);
}

glsl2hlsl_result_free(&result);
```

即使转换失败，也应对 `result` 调用 `glsl2hlsl_result_free`，因为错误诊断同样可能持有内存。`glsl2hlsl_result_free` 会把字段重置为空，重复调用是安全的；对全零结构体调用也安全。对已经持有结果的 `result` 再次调用 `glsl2hlsl_convert` 前，应先调用 `glsl2hlsl_result_free`，否则旧结果会泄漏。

`glsl2hlsl_convert` 返回的 `output` 与 `message` 都在末尾附带 NUL，但长度字段才是权威值；HLSL 文本本身不保证没有内嵌 NUL。

### 线程安全

- 不同线程可以同时调用 `glsl2hlsl_convert`，每次调用使用独立的转换状态。
- 库内部使用线程安全的通用分配器，没有可变的全局状态。
- `glsl2hlsl_version` 返回静态字符串，不需要释放。
- 同一个 `glsl2hlsl_result` 不能被多个线程同时读写。

## C++ 封装

`glsl2hlsl.hpp` 只包含头文件，封装了 C ABI 的分配与释放：

```cpp
#include <glsl2hlsl/glsl2hlsl.hpp>

#include <iostream>
#include <string_view>

int main() {
    std::string_view source =
        "#version 330 core\n"
        "in vec2 v_uv;\n"
        "uniform sampler2D u_tex;\n"
        "out vec4 frag_color;\n"
        "void main() { frag_color = texture(u_tex, v_uv); }\n";

    glsl2hlsl::Result result = glsl2hlsl::convert(source, glsl2hlsl::Stage::Fragment);

    for (const glsl2hlsl::Diagnostic &diagnostic : result.diagnostics) {
        std::cerr << glsl2hlsl::to_string(diagnostic.severity) << ":"
                  << diagnostic.line << ":" << diagnostic.column << ": "
                  << diagnostic.message << "\n";
    }

    if (!result) {
        return 1;
    }

    std::cout << result.output;
    return 0;
}
```

接口：

```cpp
namespace glsl2hlsl {

enum class Stage { Auto, Vertex, Fragment };
enum class Status { Ok, InvalidShader, OutOfMemory, InvalidArgument };
enum class Severity { Error, Warning };

struct Diagnostic {
    Severity severity;
    std::uint32_t line;
    std::uint32_t column;
    std::string message;
};

struct Result {
    Status status;
    std::string output;
    std::vector<Diagnostic> diagnostics;

    bool ok() const noexcept;
    explicit operator bool() const noexcept;
};

Result convert(std::string_view source, Stage stage = Stage::Auto);
const char *version() noexcept;

const char *to_string(Status status) noexcept;
const char *to_string(Severity severity) noexcept;

}
```

`Result` 默认构造为 `InvalidArgument`。`convert` 会在返回前释放 C 结果，因此返回的对象完全由 C++ 标准库管理。`std::string` / `std::vector` 的分配失败会以 `std::bad_alloc` 抛出；库本身不抛异常。

## 链接

### Zig 自带的 C++ 编译器

```powershell
zig c++ -std=c++23 -I zig-out/include examples/cpp/example.cpp `
    zig-out/lib/glsl2hlsl.lib -o example.exe
```

动态库方式需要让 `example.exe` 能找到 DLL，例如把 `zig-out\bin` 加入 `PATH`，或把 `glsl2hlsl.dll` 复制到可执行文件旁：

```powershell
zig c++ -std=c++23 -I zig-out/include examples/cpp/example.cpp `
    zig-out/lib/glsl2hlsl.lib -o example.exe
$env:PATH = "$PWD\zig-out\bin;$env:PATH"
.\example.exe
```

### MSVC

```bat
cl /std:c++latest /I zig-out\include examples\cpp\example.cpp zig-out\lib\glsl2hlsl.lib
```

静态库是 COFF 格式；若使用动态库，`glsl2hlsl.lib` 是导入库，运行时同样需要 `glsl2hlsl.dll`。C++ 封装要求 C++23，MSVC 请使用支持 C++23 的版本并通过 `/std:c++latest` 编译。MSVC 的 C 编译器尚不支持 C23，因此 C 调用请使用 clang 或 GCC。

### CMake

```cmake
add_library(glsl2hlsl STATIC IMPORTED)
set_target_properties(glsl2hlsl PROPERTIES
    IMPORTED_LOCATION "${CMAKE_SOURCE_DIR}/third_party/glsl2hlsl/lib/glsl2hlsl.lib"
    INTERFACE_INCLUDE_DIRECTORIES "${CMAKE_SOURCE_DIR}/third_party/glsl2hlsl/include")

target_link_libraries(your_target PRIVATE glsl2hlsl)
```

## ABI 说明

- 结构体按平台默认对齐，`size_t` 宽度必须与库一致；不支持 32 位库配 64 位程序。
- `glsl2hlsl_stage`、`glsl2hlsl_status`、`glsl2hlsl_severity` 的底层类型为 C `int`。
- 库使用自己的分配器，调用方只需要保证在同一进程中调用对应的 `glsl2hlsl_result_free`。
- 当前验证平台为 Windows x86_64；其他平台需要用对应目标重新构建。

## 测试

```powershell
zig build test
zig build c-test
zig build cpp-test
```

`zig build test` 覆盖 Zig 核心与 C ABI 的转换、错误诊断和参数校验；`zig build c-test` 用 C23 编译并运行 C 互操作测试；`zig build cpp-test` 分别用 C++23 和 C++26 编译并运行同一份 C++ 互操作测试，检查头文件、链接、结果读取和错误处理。
## DXIL 二进制发射接口

M1 新增 `glsl2hlsl_dxil_emit` 与 `glsl2hlsl_dxil_result_free`，支持程序化 SM 6.5 顶点位置透传及参数化常量片元输出。结果使用 `uint8_t*` 和长度，不保证末尾零字节，需用专用函数释放。SM 6.9 暂返回 `GLSL2HLSL_STATUS_UNSUPPORTED_TARGET`（4）；旧状态编号和文本结果结构保持不变。详细参数、所有权和当前限制见 [DXIL 文档](dxil.md#c-abi)。C++ 调用方可直接使用这组 C ABI。

## DXIL 配对源码接口

`compile_graphics(GraphicsRequest)` 编译 VS/PS，返回只移动的 `GraphicsResult`。结果持有两份字节码、反射和诊断，析构时自动释放；`vertex()`、`fragment()`、`diagnostics()` 返回借用 span，`reflection()` 返回借用的 C 结果视图，移动或销毁所属结果后应重新取得视图。

```cpp
auto program = glsl2hlsl::compile_graphics({
    .vertex = "layout(location=0) in vec4 p; void main(){gl_Position=p;}",
    .fragment = "out vec4 c; void main(){c=vec4(1);}",
    .coordinates = glsl2hlsl::Coordinates::D3D12Native
});
if (!program) {
    for (const auto &diagnostic : program.diagnostics())
        std::cerr << diagnostic.source_name << ':' << diagnostic.line
                  << ':' << diagnostic.column << ": " << diagnostic.message << '\n';
}
```

默认使用 `Coordinates::OpenGL`。此模式要求绑定反射中的 `GlCompat` cbuffer，并通过 `prepare_gl_state(state, prepared)` 同步设置 viewport、正面绕序和 DrawInstanced 的起始实例；详细步骤和数值契约见 [DXIL 文档](dxil.md#m2glsl-源码编译与反射)。单独创建 PSO 或仅上传 uniform 不足以完成 GL 状态映射。
