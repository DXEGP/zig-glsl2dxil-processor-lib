#include <glsl2hlsl/glsl2hlsl.h>
#include <stdio.h>
#include <string.h>

static int graphics_test(void) {
    const char *vertex = "layout(location=0) in vec4 p; uniform mat3 m; out vec2 uv; void main(){gl_Position=p; uv=(m*vec3(p.xy,1)).xy;}";
    const char *fragment = "in vec2 uv; uniform sampler2D tex; out vec4 c; void main(){c=texture(tex,uv);}";
    glsl2hlsl_dxil_graphics_options options = {
        .vertex_source = vertex, .vertex_source_length = strlen(vertex),
        .fragment_source = fragment, .fragment_source_length = strlen(fragment),
        .fragment_name = "test.frag", .fragment_name_length = 9,
        .shader_model = GLSL2HLSL_SM_6_5, .coordinates = GLSL2HLSL_DXIL_OPENGL
    };
    glsl2hlsl_dxil_graphics_result result = {};
    if (glsl2hlsl_dxil_compile_graphics(&options, &result) != GLSL2HLSL_STATUS_OK) return 1;
    if (result.reflection_version != 1 || result.coordinates != 0 || !result.owner) return 1;
    if (result.vertex_length < 32 || result.fragment_length < 32 || memcmp(result.vertex, "DXBC", 4)) return 1;
    if (result.uniform_count != 1 || strcmp(result.uniforms[0].name, "m") || result.uniforms[0].size != 48 || result.uniforms[0].matrix_stride != 16) return 1;
    if (result.uniforms[0].type.rows != 3 || result.uniforms[0].type.columns != 3 || result.uniforms[0].stages != 1 || result.binding_count != 4) return 1;
    if (result.signature_count < 4 || result.signatures[0].stage != GLSL2HLSL_STAGE_VERTEX) return 1;
    glsl2hlsl_dxil_graphics_result_free(&result);
    glsl2hlsl_dxil_graphics_result_free(&result);
    glsl2hlsl_dxil_graphics_result_free(nullptr);
    if (result.owner || result.uniforms || result.vertex || result.signature_count) return 1;
    options.fragment_source = "in vec3 uv; out vec4 c; void main(){c=vec4(uv,1);}";
    options.fragment_source_length = strlen(options.fragment_source);
    if (glsl2hlsl_dxil_compile_graphics(&options, &result) != GLSL2HLSL_STATUS_INVALID_SHADER) return 1;
    if (!result.diagnostic_count || result.vertex || result.fragment || result.uniforms) return 1;
    if (strcmp(result.diagnostics[0].source_name, "test.frag") || !result.diagnostics[0].message_length || !result.diagnostics[0].line) return 1;
    glsl2hlsl_dxil_graphics_result_free(&result);
    options.shader_model = GLSL2HLSL_SM_6_9;
    if (glsl2hlsl_dxil_compile_graphics(&options, &result) != GLSL2HLSL_STATUS_UNSUPPORTED_TARGET || result.owner) return 1;
    options.vertex_source = nullptr;
    if (glsl2hlsl_dxil_compile_graphics(&options, &result) != GLSL2HLSL_STATUS_INVALID_ARGUMENT || result.owner) return 1;
    if (glsl2hlsl_dxil_compile_graphics(nullptr, &result) != GLSL2HLSL_STATUS_INVALID_ARGUMENT) return 1;
    if (glsl2hlsl_dxil_compile_graphics(&options, nullptr) != GLSL2HLSL_STATUS_INVALID_ARGUMENT) return 1;
    glsl2hlsl_dxil_gl_state state = {.viewport_width=4, .viewport_height=4, .target_height=8, .depth_near=0.8f, .depth_far=0.2f, .base_instance=7};
    glsl2hlsl_dxil_gl_prepared prepared = {};
    if (glsl2hlsl_dxil_prepare_gl_state(&state, &prepared) != GLSL2HLSL_STATUS_OK || prepared.viewport[1] != 4 || prepared.start_instance_location != 7) return 1;
    state.clip_origin = 99;
    if (glsl2hlsl_dxil_prepare_gl_state(&state, &prepared) != GLSL2HLSL_STATUS_INVALID_ARGUMENT || prepared.viewport[2]) return 1;
    return 0;
}

int main(void) {
    glsl2hlsl_dxil_options options = {
        .program = GLSL2HLSL_DXIL_FRAGMENT_CONSTANT,
        .shader_model = GLSL2HLSL_SM_6_5,
        .color = {0.25f, 0.5f, 0.75f, 1.0f}
    };
    glsl2hlsl_dxil_result result = {};
    if (glsl2hlsl_dxil_emit(&options, &result) != GLSL2HLSL_STATUS_OK) return 1;
    if (result.output_length < 32 || memcmp(result.output, "DXBC", 4) != 0) return 1;
    glsl2hlsl_dxil_result_free(&result);
    glsl2hlsl_dxil_result_free(&result);
    if (result.output != nullptr || result.output_length != 0) return 1;
    options.shader_model = GLSL2HLSL_SM_6_9;
    if (glsl2hlsl_dxil_emit(&options, &result) != GLSL2HLSL_STATUS_UNSUPPORTED_TARGET) return 1;
    if (result.output != nullptr || result.output_length != 0) return 1;
    if (glsl2hlsl_dxil_emit(nullptr, &result) != GLSL2HLSL_STATUS_INVALID_ARGUMENT) return 1;
    if (glsl2hlsl_dxil_emit(&options, nullptr) != GLSL2HLSL_STATUS_INVALID_ARGUMENT) return 1;
    if (graphics_test()) return 1;
    puts("DXIL C23 binary and graphics ABI passed");
    return 0;
}
