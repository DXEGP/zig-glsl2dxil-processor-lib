#include <glsl2hlsl/glsl2hlsl.hpp>

#include <iostream>
#include <string_view>
#include <type_traits>

namespace {

bool contains(std::string_view text, std::string_view needle) {
    return text.contains(needle);
}

void print_diagnostics(const glsl2hlsl::Result &result) {
    for (const glsl2hlsl::Diagnostic &diagnostic : result.diagnostics) {
        std::cerr << glsl2hlsl::to_string(diagnostic.severity) << ":" << diagnostic.line
                  << ":" << diagnostic.column << ": " << diagnostic.message << "\n";
    }
}

int report(const char *message, int failures) {
    std::cerr << "FAIL: " << message << "\n";
    return failures + 1;
}

}

int main() {
    int failures = 0;
    static_assert(!std::is_copy_constructible_v<glsl2hlsl::GraphicsResult>);
    static_assert(std::is_nothrow_move_constructible_v<glsl2hlsl::GraphicsResult>);
    auto graphics = glsl2hlsl::compile_graphics({
        .vertex = "layout(location=0) in vec4 p; void main(){gl_Position=p;}",
        .fragment = "out vec4 c; void main(){c=vec4(1);}",
        .coordinates = glsl2hlsl::Coordinates::D3D12Native
    });
    if (!graphics || graphics.vertex().empty() || graphics.fragment().empty()) failures = report("graphics compilation failed", failures);
    const auto *original = graphics.vertex().data();
    auto moved = std::move(graphics);
    if (graphics || !moved || moved.vertex().data() != original) failures = report("graphics move construction failed", failures);
    glsl2hlsl::GraphicsResult assigned;
    assigned = std::move(moved);
    if (moved || !assigned || assigned.vertex().data() != original) failures = report("graphics move assignment failed", failures);

    constexpr std::string_view vertex_source =
        "#version 330 core\n"
        "layout(location = 0) in vec3 a_position;\n"
        "uniform mat4 u_mvp;\n"
        "void main() {\n"
        "    gl_Position = u_mvp * vec4(a_position, 1.0);\n"
        "}\n";

    const glsl2hlsl::Result vertex = glsl2hlsl::convert(vertex_source, glsl2hlsl::Stage::Vertex);
    if (!vertex) {
        print_diagnostics(vertex);
        failures = report("vertex conversion failed", failures);
    } else {
        if (!contains(vertex.output, "cbuffer Globals")) failures = report("missing cbuffer", failures);
        if (!contains(vertex.output, "mul(u_mvp")) failures = report("missing mul", failures);
        if (!contains(vertex.output, "SV_Position")) failures = report("missing SV_Position", failures);
        if (!contains(vertex.output, "POSITION")) failures = report("missing POSITION semantic", failures);
    }

    constexpr std::string_view fragment_source =
        "#version 330 core\n"
        "in vec2 v_uv;\n"
        "uniform sampler2D u_tex;\n"
        "out vec4 frag_color;\n"
        "void main() {\n"
        "    frag_color = texture(u_tex, v_uv);\n"
        "}\n";

    const glsl2hlsl::Result fragment = glsl2hlsl::convert(fragment_source);
    if (!fragment) {
        print_diagnostics(fragment);
        failures = report("fragment conversion failed", failures);
    } else {
        if (!contains(fragment.output, "Texture2D")) failures = report("missing Texture2D", failures);
        if (!contains(fragment.output, "SamplerState")) failures = report("missing SamplerState", failures);
        if (!contains(fragment.output, ".Sample(")) failures = report("missing Sample call", failures);
        if (!contains(fragment.output, "SV_Target0")) failures = report("missing SV_Target0", failures);
    }

    const glsl2hlsl::Result invalid = glsl2hlsl::convert("void main() { gl_Position = ; }", glsl2hlsl::Stage::Auto);
    if (invalid.ok()) failures = report("invalid shader was accepted", failures);
    if (invalid.diagnostics.empty()) failures = report("invalid shader had no diagnostics", failures);

    const glsl2hlsl::Result warning = glsl2hlsl::convert("void main() {}\n");
    if (!warning.ok()) failures = report("warning shader failed", failures);
    if (warning.diagnostics.empty()) failures = report("missing stage inference warning", failures);

    const glsl2hlsl::Result bad_argument = glsl2hlsl::convert("", static_cast<glsl2hlsl::Stage>(99));
    if (bad_argument.status != glsl2hlsl::Status::InvalidArgument) {
        failures = report("invalid stage was not rejected", failures);
    }

    if (glsl2hlsl::version() == nullptr || glsl2hlsl::version()[0] == '\0') {
        failures = report("missing version", failures);
    }

    if (failures == 0) {
        std::cout << "cpp interop ok\n";
    }
    return failures == 0 ? 0 : 1;
}
