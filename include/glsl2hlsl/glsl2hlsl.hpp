#ifndef GLSL2HLSL_HPP
#define GLSL2HLSL_HPP

#include "glsl2hlsl.h"

#include <cstdint>
#include <span>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace glsl2hlsl {

enum class Stage {
    Auto = GLSL2HLSL_STAGE_AUTO,
    Vertex = GLSL2HLSL_STAGE_VERTEX,
    Fragment = GLSL2HLSL_STAGE_FRAGMENT
};

enum class Status {
    Ok = GLSL2HLSL_STATUS_OK,
    InvalidShader = GLSL2HLSL_STATUS_INVALID_SHADER,
    OutOfMemory = GLSL2HLSL_STATUS_OUT_OF_MEMORY,
    InvalidArgument = GLSL2HLSL_STATUS_INVALID_ARGUMENT,
    UnsupportedTarget = GLSL2HLSL_STATUS_UNSUPPORTED_TARGET
};

enum class Severity {
    Error = GLSL2HLSL_SEVERITY_ERROR,
    Warning = GLSL2HLSL_SEVERITY_WARNING
};

struct Diagnostic {
    Severity severity = Severity::Error;
    std::uint32_t line = 0;
    std::uint32_t column = 0;
    std::string message;
};

struct Result {
    Status status = Status::InvalidArgument;
    std::string output;
    std::vector<Diagnostic> diagnostics;

    [[nodiscard]] bool ok() const noexcept { return status == Status::Ok; }
    [[nodiscard]] explicit operator bool() const noexcept { return ok(); }
};

inline const char *to_string(Status status) noexcept {
    switch (status) {
    case Status::Ok:
        return "ok";
    case Status::InvalidShader:
        return "invalid shader";
    case Status::OutOfMemory:
        return "out of memory";
    case Status::InvalidArgument:
        return "invalid argument";
    case Status::UnsupportedTarget:
        return "unsupported target";
    }
    return "unknown";
}

inline const char *to_string(Severity severity) noexcept {
    switch (severity) {
    case Severity::Error:
        return "error";
    case Severity::Warning:
        return "warning";
    }
    return "unknown";
}

namespace detail {

struct ResultOwner {
    glsl2hlsl_result value{};

    ResultOwner() = default;
    ResultOwner(const ResultOwner &) = delete;
    ResultOwner &operator=(const ResultOwner &) = delete;

    ~ResultOwner() { glsl2hlsl_result_free(&value); }
};

}

[[nodiscard]] inline Result convert(std::string_view source, Stage stage = Stage::Auto) {
    detail::ResultOwner owner;
    const char *data = source.empty() ? "" : source.data();
    const glsl2hlsl_status status = glsl2hlsl_convert(
        data,
        source.size(),
        static_cast<glsl2hlsl_stage>(std::to_underlying(stage)),
        &owner.value);

    Result result;
    result.status = static_cast<Status>(status);

    if (owner.value.output != nullptr) {
        result.output.assign(owner.value.output, owner.value.output_length);
    }

    result.diagnostics.reserve(owner.value.diagnostic_count);
    for (size_t i = 0; i < owner.value.diagnostic_count; ++i) {
        const glsl2hlsl_diagnostic &raw = owner.value.diagnostics[i];
        const char *message = raw.message != nullptr ? raw.message : "";
        result.diagnostics.push_back(Diagnostic{
            static_cast<Severity>(raw.severity),
            raw.line,
            raw.column,
            std::string(message, raw.message_length)});
    }

    return result;
}

[[nodiscard]] inline const char *version() noexcept {
    return glsl2hlsl_version();
}

enum class Coordinates {
    OpenGL = GLSL2HLSL_DXIL_OPENGL,
    D3D12Native = GLSL2HLSL_DXIL_D3D12_NATIVE
};
enum class BindingMode {
    DescriptorTables = GLSL2HLSL_DXIL_DESCRIPTOR_TABLES,
    DirectHeap = GLSL2HLSL_DXIL_DIRECT_HEAP
};

struct GraphicsRequest {
    std::string_view vertex;
    std::string_view fragment;
    std::string_view vertex_name = "vertex";
    std::string_view fragment_name = "fragment";
    glsl2hlsl_shader_model shader_model = GLSL2HLSL_SM_6_5;
    Coordinates coordinates = Coordinates::OpenGL;
    BindingMode binding_mode = BindingMode::DescriptorTables;
    std::uint32_t resource_heap_base = 0;
    std::uint32_t sampler_heap_base = 0;
    std::span<const glsl2hlsl_dxil_file> files{};
    std::span<const glsl2hlsl_dxil_define> defines{};
    std::span<const glsl2hlsl_dxil_text> include_dirs{};
    const glsl2hlsl_dxil_limits *limits = nullptr;
    bool optimize = false;
    glsl2hlsl_dxil_session *session = nullptr;
};

class CompileSession {
    glsl2hlsl_dxil_session *value_;
public:
    explicit CompileSession(std::size_t entries = 32, std::size_t bytes = 64 * 1024 * 1024) noexcept
        : value_(glsl2hlsl_dxil_session_create(entries, bytes)) {}
    CompileSession(const CompileSession &) = delete;
    CompileSession &operator=(const CompileSession &) = delete;
    CompileSession(CompileSession &&other) noexcept : value_(std::exchange(other.value_, nullptr)) {}
    CompileSession &operator=(CompileSession &&other) noexcept {
        if (this != &other) { glsl2hlsl_dxil_session_free(value_); value_ = std::exchange(other.value_, nullptr); }
        return *this;
    }
    ~CompileSession() { glsl2hlsl_dxil_session_free(value_); }
    [[nodiscard]] glsl2hlsl_dxil_session *get() const noexcept { return value_; }
    [[nodiscard]] glsl2hlsl_dxil_cache_stats stats() const noexcept {
        glsl2hlsl_dxil_cache_stats stats{};
        if (glsl2hlsl_dxil_session_stats(value_, &stats) != GLSL2HLSL_STATUS_OK) return {};
        return stats;
    }
};

class GraphicsResult {
    glsl2hlsl_dxil_graphics_result value_{};

public:
    GraphicsResult() = default;
    GraphicsResult(const GraphicsResult &) = delete;
    GraphicsResult &operator=(const GraphicsResult &) = delete;
    GraphicsResult(GraphicsResult &&other) noexcept : value_(std::exchange(other.value_, {})) {}
    GraphicsResult &operator=(GraphicsResult &&other) noexcept {
        if (this != &other) {
            glsl2hlsl_dxil_graphics_result_free(&value_);
            value_ = std::exchange(other.value_, {});
        }
        return *this;
    }
    ~GraphicsResult() { glsl2hlsl_dxil_graphics_result_free(&value_); }

    [[nodiscard]] Status status() const noexcept { return static_cast<Status>(value_.status); }
    [[nodiscard]] explicit operator bool() const noexcept { return value_.owner && status() == Status::Ok; }
    [[nodiscard]] std::span<const std::uint8_t> vertex() const noexcept { return {value_.vertex, value_.vertex_length}; }
    [[nodiscard]] std::span<const std::uint8_t> fragment() const noexcept { return {value_.fragment, value_.fragment_length}; }
    [[nodiscard]] const glsl2hlsl_dxil_graphics_result &reflection() const noexcept { return value_; }
    [[nodiscard]] std::span<const glsl2hlsl_dxil_graphics_diagnostic> diagnostics() const noexcept { return {value_.diagnostics, value_.diagnostic_count}; }
    [[nodiscard]] glsl2hlsl_dxil_execution_info execution_info() const noexcept {
        glsl2hlsl_dxil_execution_info info{};
        const auto status = glsl2hlsl_dxil_graphics_execution_info(&value_, &info);
        if (status != GLSL2HLSL_STATUS_OK) return {};
        return info;
    }

    friend GraphicsResult compile_graphics(const GraphicsRequest &) noexcept;
};

[[nodiscard]] inline GraphicsResult compile_graphics(const GraphicsRequest &request) noexcept {
    glsl2hlsl_dxil_graphics_options options{};
    options.vertex_source = request.vertex.data();
    options.vertex_source_length = request.vertex.size();
    options.fragment_source = request.fragment.data();
    options.fragment_source_length = request.fragment.size();
    options.vertex_name = request.vertex_name.data();
    options.vertex_name_length = request.vertex_name.size();
    options.fragment_name = request.fragment_name.data();
    options.fragment_name_length = request.fragment_name.size();
    options.shader_model = request.shader_model;
    options.coordinates = static_cast<glsl2hlsl_dxil_coordinates>(std::to_underlying(request.coordinates));
    GraphicsResult result;
    glsl2hlsl_dxil_graphics_options_ex extended{};
    extended.struct_size = sizeof(extended);
    extended.base = options;
    extended.binding_mode = static_cast<glsl2hlsl_dxil_binding_mode>(std::to_underlying(request.binding_mode));
    extended.resource_heap_base = request.resource_heap_base;
    extended.sampler_heap_base = request.sampler_heap_base;
    glsl2hlsl_dxil_graphics_options_v2 versioned{};
    versioned.struct_size = sizeof(versioned);
    versioned.base = extended;
    versioned.files = request.files.data(); versioned.file_count = request.files.size();
    versioned.defines = request.defines.data(); versioned.define_count = request.defines.size();
    versioned.include_dirs = request.include_dirs.data(); versioned.include_dir_count = request.include_dirs.size();
    versioned.limits = request.limits; versioned.optimization = request.optimize ? 1 : 0;
    result.value_.status = glsl2hlsl_dxil_compile_graphics_v2(request.session, &versioned, &result.value_);
    return result;
}

[[nodiscard]] inline Status prepare_gl_state(const glsl2hlsl_dxil_gl_state &state, glsl2hlsl_dxil_gl_prepared &prepared) noexcept {
    return static_cast<Status>(glsl2hlsl_dxil_prepare_gl_state(&state, &prepared));
}

}

#endif
