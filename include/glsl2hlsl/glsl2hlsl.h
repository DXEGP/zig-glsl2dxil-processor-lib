#ifndef GLSL2HLSL_H
#define GLSL2HLSL_H

#include <stddef.h>
#include <stdint.h>

#if defined(__cplusplus)
#  if (defined(_MSVC_LANG) && _MSVC_LANG < 202302L) || (!defined(_MSVC_LANG) && __cplusplus < 202302L)
#    error "glsl2hlsl requires C++23 or newer"
#  endif
#elif !defined(__STDC_VERSION__) || __STDC_VERSION__ < 202311L
#error "glsl2hlsl requires C23 or newer"
#endif

#if defined(_WIN32) && defined(GLSL2HLSL_BUILD_DLL)
#define GLSL2HLSL_API __declspec(dllexport)
#else
#define GLSL2HLSL_API
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef enum glsl2hlsl_stage {
    GLSL2HLSL_STAGE_AUTO = 0,
    GLSL2HLSL_STAGE_VERTEX = 1,
    GLSL2HLSL_STAGE_FRAGMENT = 2
} glsl2hlsl_stage;

typedef enum glsl2hlsl_status {
    GLSL2HLSL_STATUS_OK = 0,
    GLSL2HLSL_STATUS_INVALID_SHADER = 1,
    GLSL2HLSL_STATUS_OUT_OF_MEMORY = 2,
    GLSL2HLSL_STATUS_INVALID_ARGUMENT = 3,
    GLSL2HLSL_STATUS_UNSUPPORTED_TARGET = 4
} glsl2hlsl_status;

typedef enum glsl2hlsl_severity {
    GLSL2HLSL_SEVERITY_ERROR = 0,
    GLSL2HLSL_SEVERITY_WARNING = 1
} glsl2hlsl_severity;

typedef struct glsl2hlsl_diagnostic {
    glsl2hlsl_severity severity;
    uint32_t line;
    uint32_t column;
    char *message;
    size_t message_length;
} glsl2hlsl_diagnostic;

typedef struct glsl2hlsl_result {
    glsl2hlsl_status status;
    char *output;
    size_t output_length;
    glsl2hlsl_diagnostic *diagnostics;
    size_t diagnostic_count;
} glsl2hlsl_result;

[[nodiscard]] GLSL2HLSL_API glsl2hlsl_status glsl2hlsl_convert(
    const char *source,
    size_t source_length,
    glsl2hlsl_stage stage,
    glsl2hlsl_result *result);

GLSL2HLSL_API void glsl2hlsl_result_free(glsl2hlsl_result *result);

GLSL2HLSL_API const char *glsl2hlsl_version(void);

typedef enum glsl2hlsl_dxil_program {
    GLSL2HLSL_DXIL_VERTEX_PASSTHROUGH = 0,
    GLSL2HLSL_DXIL_FRAGMENT_CONSTANT = 1
} glsl2hlsl_dxil_program;

typedef enum glsl2hlsl_shader_model {
    GLSL2HLSL_SM_6_5 = 65,
    GLSL2HLSL_SM_6_9 = 69
} glsl2hlsl_shader_model;

typedef struct glsl2hlsl_dxil_options {
    glsl2hlsl_dxil_program program;
    glsl2hlsl_shader_model shader_model;
    float color[4];
} glsl2hlsl_dxil_options;

typedef struct glsl2hlsl_dxil_result {
    glsl2hlsl_status status;
    uint8_t *output;
    size_t output_length;
} glsl2hlsl_dxil_result;

[[nodiscard]] GLSL2HLSL_API glsl2hlsl_status glsl2hlsl_dxil_emit(
    const glsl2hlsl_dxil_options *options,
    glsl2hlsl_dxil_result *result);

GLSL2HLSL_API void glsl2hlsl_dxil_result_free(glsl2hlsl_dxil_result *result);

typedef enum glsl2hlsl_dxil_coordinates {
    GLSL2HLSL_DXIL_OPENGL = 0,
    GLSL2HLSL_DXIL_D3D12_NATIVE = 1
} glsl2hlsl_dxil_coordinates;

typedef enum glsl2hlsl_dxil_scalar {
    GLSL2HLSL_DXIL_VOID = 0,
    GLSL2HLSL_DXIL_BOOL = 1,
    GLSL2HLSL_DXIL_INT = 2,
    GLSL2HLSL_DXIL_UINT = 3,
    GLSL2HLSL_DXIL_FLOAT = 4,
    GLSL2HLSL_DXIL_SAMPLER = 5,
    GLSL2HLSL_DXIL_STRUCT = 6
} glsl2hlsl_dxil_scalar;

typedef enum glsl2hlsl_dxil_resource_class {
    GLSL2HLSL_DXIL_SRV = 0,
    GLSL2HLSL_DXIL_UAV = 1,
    GLSL2HLSL_DXIL_CBUFFER = 2,
    GLSL2HLSL_DXIL_SAMPLER_STATE = 3
} glsl2hlsl_dxil_resource_class;

typedef struct glsl2hlsl_dxil_type {
    uint32_t scalar;
    uint32_t rows;
    uint32_t columns;
    uint32_t array_length;
    uint32_t structure_index;
} glsl2hlsl_dxil_type;

typedef struct glsl2hlsl_dxil_uniform {
    const char *name;
    size_t name_length;
    glsl2hlsl_dxil_type type;
    uint32_t offset;
    uint32_t size;
    uint32_t array_stride;
    uint32_t matrix_stride;
    uint32_t stages;
} glsl2hlsl_dxil_uniform;

typedef struct glsl2hlsl_dxil_binding {
    const char *name;
    size_t name_length;
    uint32_t resource_class;
    uint32_t binding;
    uint32_t space;
    uint32_t size;
    uint32_t stages;
} glsl2hlsl_dxil_binding;

typedef struct glsl2hlsl_dxil_field {
    const char *name;
    size_t name_length;
    glsl2hlsl_dxil_type type;
    uint32_t offset;
} glsl2hlsl_dxil_field;

typedef struct glsl2hlsl_dxil_structure {
    const char *name;
    size_t name_length;
    const glsl2hlsl_dxil_field *fields;
    size_t field_count;
    uint32_t size;
} glsl2hlsl_dxil_structure;

typedef struct glsl2hlsl_dxil_signature {
    const char *name;
    size_t name_length;
    uint32_t semantic_index;
    uint32_t row;
    uint32_t columns;
    uint32_t scalar;
    uint32_t semantic;
    uint32_t interpolation;
    uint32_t stage;
    uint32_t is_input;
} glsl2hlsl_dxil_signature;

typedef struct glsl2hlsl_dxil_graphics_diagnostic {
    uint32_t severity;
    uint32_t stage;
    uint32_t code;
    uint32_t line;
    uint32_t column;
    const char *source_name;
    size_t source_name_length;
    const char *message;
    size_t message_length;
} glsl2hlsl_dxil_graphics_diagnostic;

typedef enum glsl2hlsl_dxil_diagnostic_code {
    GLSL2HLSL_DXIL_DIAGNOSTIC_SOURCE = 0,
    GLSL2HLSL_DXIL_DIAGNOSTIC_UNSUPPORTED = 1,
    GLSL2HLSL_DXIL_DIAGNOSTIC_TYPE_MISMATCH = 2,
    GLSL2HLSL_DXIL_DIAGNOSTIC_LINK = 3,
    GLSL2HLSL_DXIL_DIAGNOSTIC_INVALID_IR = 4
} glsl2hlsl_dxil_diagnostic_code;

typedef struct glsl2hlsl_dxil_graphics_options {
    const char *vertex_source;
    size_t vertex_source_length;
    const char *vertex_name;
    size_t vertex_name_length;
    const char *fragment_source;
    size_t fragment_source_length;
    const char *fragment_name;
    size_t fragment_name_length;
    glsl2hlsl_shader_model shader_model;
    glsl2hlsl_dxil_coordinates coordinates;
} glsl2hlsl_dxil_graphics_options;

typedef struct glsl2hlsl_dxil_graphics_result {
    glsl2hlsl_status status;
    void *owner;
    const uint8_t *vertex;
    size_t vertex_length;
    const uint8_t *fragment;
    size_t fragment_length;
    uint32_t reflection_version;
    uint32_t coordinates;
    const glsl2hlsl_dxil_uniform *uniforms;
    size_t uniform_count;
    const glsl2hlsl_dxil_binding *bindings;
    size_t binding_count;
    const glsl2hlsl_dxil_structure *structures;
    size_t structure_count;
    const glsl2hlsl_dxil_signature *signatures;
    size_t signature_count;
    const glsl2hlsl_dxil_graphics_diagnostic *diagnostics;
    size_t diagnostic_count;
} glsl2hlsl_dxil_graphics_result;

[[nodiscard]] GLSL2HLSL_API glsl2hlsl_status glsl2hlsl_dxil_compile_graphics(
    const glsl2hlsl_dxil_graphics_options *options,
    glsl2hlsl_dxil_graphics_result *result);

GLSL2HLSL_API void glsl2hlsl_dxil_graphics_result_free(glsl2hlsl_dxil_graphics_result *result);

typedef enum glsl2hlsl_dxil_binding_mode {
    GLSL2HLSL_DXIL_DESCRIPTOR_TABLES = 0,
    GLSL2HLSL_DXIL_DIRECT_HEAP = 1
} glsl2hlsl_dxil_binding_mode;

typedef struct glsl2hlsl_dxil_graphics_options_ex {
    size_t struct_size;
    glsl2hlsl_dxil_graphics_options base;
    glsl2hlsl_dxil_binding_mode binding_mode;
    uint32_t resource_heap_base;
    uint32_t sampler_heap_base;
} glsl2hlsl_dxil_graphics_options_ex;

typedef struct glsl2hlsl_dxil_heap_binding {
    uint32_t binding_index;
    uint32_t heap_index;
} glsl2hlsl_dxil_heap_binding;

typedef struct glsl2hlsl_dxil_execution_info {
    uint32_t shader_model;
    uint32_t dxil_version;
    uint32_t validator_version;
    uint32_t psv_version;
    uint32_t resource_binding_tier;
    uint32_t root_signature_version;
    uint32_t root_flags;
    uint32_t native_vectors;
    uint64_t feature_flags;
    glsl2hlsl_dxil_binding_mode binding_mode;
    const glsl2hlsl_dxil_heap_binding *heap_bindings;
    size_t heap_binding_count;
} glsl2hlsl_dxil_execution_info;

[[nodiscard]] GLSL2HLSL_API glsl2hlsl_status glsl2hlsl_dxil_compile_graphics_ex(
    const glsl2hlsl_dxil_graphics_options_ex *options,
    glsl2hlsl_dxil_graphics_result *result);

[[nodiscard]] GLSL2HLSL_API glsl2hlsl_status glsl2hlsl_dxil_graphics_execution_info(
    const glsl2hlsl_dxil_graphics_result *result,
    glsl2hlsl_dxil_execution_info *info);

typedef enum glsl2hlsl_dxil_clip_origin {
    GLSL2HLSL_DXIL_LOWER_LEFT = 0,
    GLSL2HLSL_DXIL_UPPER_LEFT = 1
} glsl2hlsl_dxil_clip_origin;

typedef enum glsl2hlsl_dxil_clip_depth {
    GLSL2HLSL_DXIL_NEGATIVE_ONE_TO_ONE = 0,
    GLSL2HLSL_DXIL_ZERO_TO_ONE = 1
} glsl2hlsl_dxil_clip_depth;

typedef enum glsl2hlsl_dxil_winding {
    GLSL2HLSL_DXIL_CCW = 0,
    GLSL2HLSL_DXIL_CW = 1
} glsl2hlsl_dxil_winding;

typedef struct glsl2hlsl_dxil_gl_state {
    uint32_t clip_origin;
    uint32_t clip_depth;
    uint32_t winding;
    float viewport_x;
    float viewport_y;
    float viewport_width;
    float viewport_height;
    float target_height;
    float depth_near;
    float depth_far;
    uint32_t base_instance;
} glsl2hlsl_dxil_gl_state;

typedef struct glsl2hlsl_dxil_gl_prepared {
    uint32_t constants[8];
    float viewport[6];
    uint32_t front_counter_clockwise;
    uint32_t start_instance_location;
} glsl2hlsl_dxil_gl_prepared;

[[nodiscard]] GLSL2HLSL_API glsl2hlsl_status glsl2hlsl_dxil_prepare_gl_state(
    const glsl2hlsl_dxil_gl_state *state,
    glsl2hlsl_dxil_gl_prepared *prepared);

#ifdef __cplusplus
}
#endif

#endif
