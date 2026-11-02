#include <windows.h>
#include <d3d12.h>
#include <d3d12sdklayers.h>
#include <dxgi1_6.h>
#include <wrl/client.h>
#include <glsl2hlsl/glsl2hlsl.hpp>
#include <algorithm>
#include <array>
#include <bit>
#include <chrono>
#include <cmath>
#include <cstring>
#include <fstream>
#include <functional>
#include <iostream>
#include <iterator>
#include <map>
#include <sstream>
#include <stdexcept>
#include <vector>

using Microsoft::WRL::ComPtr;
#if defined(GLSL2HLSL_TEST_AGILITY)
extern "C" {
__declspec(dllexport) extern const UINT D3D12SDKVersion = GLSL2HLSL_TEST_AGILITY;
__declspec(dllexport) extern const char *D3D12SDKPath = ".\\agility\\";
}
#endif
using Color = std::array<float, 4>;
using Attributes = std::map<unsigned, std::array<Color, 3>>;
static constexpr unsigned extent = 16;
static constexpr Color clear_color = {-9, -9, -9, -9};
static ID3D12InfoQueue *active_messages = nullptr;
static bool reference_coordinates = false;
static unsigned compilation_index = 0;
static bool modern_target = false;
static bool direct_heap = false;
static bool optimize_programs = false;

static std::string reflection_key(const glsl2hlsl_dxil_graphics_result &value) {
    std::ostringstream key;
    const auto type = [&key](const glsl2hlsl_dxil_type &typ) {
        key << typ.scalar << ',' << typ.rows << ',' << typ.columns << ',' << typ.array_length << ',' << typ.structure_index << ';';
    };
    key << value.reflection_version << ',' << value.coordinates << ',' << value.uniform_count << ',' << value.binding_count << ',' << value.structure_count << ',' << value.signature_count << ';';
    for (size_t index = 0; index < value.uniform_count; ++index) {
        const auto &uniform = value.uniforms[index];
        key << uniform.name << ':'; type(uniform.type);
        key << uniform.offset << ',' << uniform.size << ',' << uniform.array_stride << ',' << uniform.matrix_stride << ',' << uniform.stages << ';';
    }
    for (size_t index = 0; index < value.binding_count; ++index) {
        const auto &binding = value.bindings[index];
        key << binding.name << ':' << binding.resource_class << ',' << binding.binding << ',' << binding.space << ',' << binding.size << ',' << binding.stages << ';';
    }
    for (size_t index = 0; index < value.structure_count; ++index) {
        const auto &structure = value.structures[index];
        key << structure.name << ':' << structure.size << ',' << structure.field_count << ';';
        for (size_t field_index = 0; field_index < structure.field_count; ++field_index) {
            const auto &field = structure.fields[field_index];
            key << field.name << ':' << field.offset << ';'; type(field.type);
        }
    }
    for (size_t index = 0; index < value.signature_count; ++index) {
        const auto &signature = value.signatures[index];
        key << signature.name << ':' << signature.semantic_index << ',' << signature.row << ',' << signature.columns << ',' << signature.scalar << ',' << signature.semantic << ',' << signature.interpolation << ',' << signature.stage << ',' << signature.is_input << ';';
    }
    return key.str();
}

static void require(bool condition, const std::string &message) {
    if (!condition) throw std::runtime_error(message);
}

static void check(HRESULT status) {
    if (FAILED(status)) {
        if (active_messages) for (UINT64 index = 0; index < active_messages->GetNumStoredMessages(); ++index) {
            SIZE_T size = 0; active_messages->GetMessage(index, nullptr, &size); std::vector<char> storage(size);
            auto *message = reinterpret_cast<D3D12_MESSAGE *>(storage.data());
            if (SUCCEEDED(active_messages->GetMessage(index, message, &size))) std::cerr << message->pDescription << '\n';
        }
        std::cerr << "HRESULT=0x" << std::hex << static_cast<unsigned long>(status) << std::dec << '\n';
        throw std::runtime_error("D3D12 operation failed");
    }
}

static void ensure_no_compiler() {
    require(!GetModuleHandleW(L"dxcompiler.dll") && !GetModuleHandleW(L"dxil.dll"), "compiler DLL loaded in source renderer");
}

static std::string read_source(const char *path) {
    std::ifstream input(path, std::ios::binary);
    require(bool(input), std::string("cannot read ") + path);
    return {std::istreambuf_iterator<char>(input), std::istreambuf_iterator<char>()};
}

static glsl2hlsl::GraphicsResult compile(std::string_view vertex, std::string_view fragment, bool native = false, std::span<const glsl2hlsl_dxil_file> files = {}) {
    auto result = glsl2hlsl::compile_graphics({.vertex=vertex, .fragment=fragment,
        .shader_model=modern_target ? GLSL2HLSL_SM_6_9 : GLSL2HLSL_SM_6_5,
        .coordinates=native ? glsl2hlsl::Coordinates::D3D12Native : glsl2hlsl::Coordinates::OpenGL,
        .binding_mode=direct_heap ? glsl2hlsl::BindingMode::DirectHeap : glsl2hlsl::BindingMode::DescriptorTables,
        .resource_heap_base=3, .sampler_heap_base=5, .files=files, .optimize=optimize_programs});
    for (const auto &diagnostic : result.diagnostics())
        std::cerr << diagnostic.source_name << ':' << diagnostic.line << ':' << diagnostic.column << ": " << diagnostic.message << '\n';
    require(bool(result), "GLSL source compilation failed");
    if (modern_target || optimize_programs) {
        auto baseline = glsl2hlsl::compile_graphics({.vertex=vertex, .fragment=fragment,
            .coordinates=native ? glsl2hlsl::Coordinates::D3D12Native : glsl2hlsl::Coordinates::OpenGL, .files=files});
        require(bool(baseline) && reflection_key(baseline.reflection()) == reflection_key(result.reflection()), "SM6.5/6.9 resource, layout or stage interface mismatch");
    }
    const auto prefix = std::string("zig-out/dxil/") + (direct_heap ? "m3-heap" : modern_target ? "m3" : "m2") + "/runtime-" + std::to_string(compilation_index++);
    std::ofstream(prefix+".vert.dxil",std::ios::binary).write(reinterpret_cast<const char *>(result.vertex().data()),result.vertex().size());
    std::ofstream(prefix+".frag.dxil",std::ios::binary).write(reinterpret_cast<const char *>(result.fragment().data()),result.fragment().size());
    ensure_no_compiler();
    return result;
}

static D3D12_HEAP_PROPERTIES heap(D3D12_HEAP_TYPE type) {
    D3D12_HEAP_PROPERTIES value{};
    value.Type = type;
    value.CreationNodeMask = value.VisibleNodeMask = 1;
    return value;
}

static D3D12_RESOURCE_DESC buffer_desc(UINT64 size) {
    D3D12_RESOURCE_DESC value{};
    value.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER;
    value.Width = size;
    value.Height = value.DepthOrArraySize = value.MipLevels = value.SampleDesc.Count = 1;
    value.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
    return value;
}

static D3D12_RESOURCE_DESC texture_desc(DXGI_FORMAT format, unsigned mips, D3D12_RESOURCE_FLAGS flags) {
    D3D12_RESOURCE_DESC value{};
    value.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
    value.Width = value.Height = extent;
    value.DepthOrArraySize = value.SampleDesc.Count = 1;
    value.MipLevels = static_cast<UINT16>(mips);
    value.Format = format;
    value.Flags = flags;
    return value;
}

static D3D12_RESOURCE_BARRIER transition(ID3D12Resource *resource, D3D12_RESOURCE_STATES before, D3D12_RESOURCE_STATES after) {
    D3D12_RESOURCE_BARRIER value{};
    value.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    value.Transition.pResource = resource;
    value.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
    value.Transition.StateBefore = before;
    value.Transition.StateAfter = after;
    return value;
}

static Attributes fullscreen(float z = 0, float w = 1) {
    return {{0, {{{-w, -w, z, w}, {-w, 3*w, z, w}, {3*w, -w, z, w}}}}};
}

static std::array<Color, 3> constant_attribute(Color value) { return {value, value, value}; }

static Color texel(unsigned texture, unsigned mip, unsigned x, unsigned y) {
    return {0.03f + float(x)*0.02f + float(texture)*0.17f,
            0.05f + float(y)*0.025f + float(mip)*0.13f,
            0.09f + float(x + 2*y)*0.01f + float(texture)*0.11f,
            (x % 4 == 0) ? 0.025f : 0.8f};
}

static Color sample(unsigned texture, float u, float v, unsigned mip = 0) {
    const unsigned size = extent >> mip;
    const unsigned x = static_cast<unsigned>(std::clamp(int(std::floor(u*float(size))), 0, int(size)-1));
    const unsigned y = static_cast<unsigned>(std::clamp(int(std::floor(v*float(size))), 0, int(size)-1));
    return texel(texture, mip, x, y);
}

struct Draw {
    Attributes attributes = fullscreen();
    std::map<std::string, std::vector<std::uint32_t>> uniforms;
    glsl2hlsl_dxil_gl_state state{0, 0, 0, 0, 0, float(extent), float(extent), float(extent), 0, 1, 0};
    unsigned instances = 1;
    bool cull_back = false;
    bool clockwise_mesh = false;
    bool depth_test = false;
    bool no_coverage = false;
    std::function<Color(unsigned, unsigned, unsigned)> expected;
    std::function<float(unsigned, unsigned)> expected_depth;

    void floats(std::string name, std::initializer_list<float> values) {
        auto &words = uniforms[std::move(name)];
        words.clear();
        for (float value : values) words.push_back(std::bit_cast<std::uint32_t>(value));
    }
    void integer(std::string name, std::int32_t value) { uniforms[std::move(name)] = {std::bit_cast<std::uint32_t>(value)}; }
};

class Renderer {
    ID3D12Device *device;
    ComPtr<ID3D12CommandQueue> queue;
    std::map<std::string, std::vector<float>> baseline_pixels;

    ComPtr<ID3D12Resource> resource(const D3D12_RESOURCE_DESC &desc, D3D12_HEAP_TYPE type, D3D12_RESOURCE_STATES state) {
        const auto properties = heap(type);
        ComPtr<ID3D12Resource> value;
        check(device->CreateCommittedResource(&properties, D3D12_HEAP_FLAG_NONE, &desc, state, nullptr, IID_PPV_ARGS(&value)));
        return value;
    }

    ComPtr<ID3D12Resource> upload(const void *data, size_t size) {
        auto value = resource(buffer_desc(std::max<size_t>(size, 256)), D3D12_HEAP_TYPE_UPLOAD, D3D12_RESOURCE_STATE_GENERIC_READ);
        void *mapped;
        D3D12_RANGE range{};
        check(value->Map(0, &range, &mapped));
        std::memcpy(mapped, data, size);
        value->Unmap(0, nullptr);
        return value;
    }

    ComPtr<ID3D12DescriptorHeap> descriptors(D3D12_DESCRIPTOR_HEAP_TYPE type, unsigned count, bool visible) {
        D3D12_DESCRIPTOR_HEAP_DESC desc{};
        desc.Type = type;
        desc.NumDescriptors = count;
        desc.Flags = visible ? D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE : D3D12_DESCRIPTOR_HEAP_FLAG_NONE;
        ComPtr<ID3D12DescriptorHeap> result;
        check(device->CreateDescriptorHeap(&desc, IID_PPV_ARGS(&result)));
        return result;
    }

public:
    explicit Renderer(ID3D12Device *value) : device(value) {
        D3D12_COMMAND_QUEUE_DESC desc{};
        check(device->CreateCommandQueue(&desc, IID_PPV_ARGS(&queue)));
    }

    void run(const std::string &name, const glsl2hlsl::GraphicsResult &program, const Draw &draw) {
        std::cout << "case=" << name << std::endl;
        const auto &reflection = program.reflection();
        const auto execution = program.execution_info();
        const bool heap_mode = execution.binding_mode == GLSL2HLSL_DXIL_DIRECT_HEAP;
        glsl2hlsl_dxil_gl_prepared prepared{};
        require(glsl2hlsl::prepare_gl_state(draw.state, prepared) == glsl2hlsl::Status::Ok, "invalid GL state in test");
        ComPtr<ID3D12InfoQueue> messages;
        check(device->QueryInterface(IID_PPV_ARGS(&messages)));
        active_messages = messages.Get();
        messages->ClearStoredMessages();

        std::vector<D3D12_ROOT_PARAMETER> parameters(reflection.binding_count);
        std::vector<D3D12_DESCRIPTOR_RANGE> ranges(reflection.binding_count);
        unsigned srv_count = 0, sampler_count = 0;
        for (size_t index = 0; index < reflection.binding_count; ++index) {
            const auto &binding = reflection.bindings[index];
            if (heap_mode) {
                require(execution.heap_binding_count == reflection.binding_count && execution.heap_bindings[index].binding_index == index, "heap reflection mismatch");
                const auto count = execution.heap_bindings[index].heap_index + 1;
                if (binding.resource_class == GLSL2HLSL_DXIL_SAMPLER_STATE) sampler_count = std::max(sampler_count, count);
                else srv_count = std::max(srv_count, count);
                continue;
            }
            auto &parameter = parameters[index];
            parameter.ShaderVisibility = D3D12_SHADER_VISIBILITY_ALL;
            if (binding.resource_class == GLSL2HLSL_DXIL_CBUFFER) {
                parameter.ParameterType = D3D12_ROOT_PARAMETER_TYPE_CBV;
                parameter.Descriptor = {binding.binding, binding.space};
            } else {
                auto &range = ranges[index];
                const bool sampler = binding.resource_class == GLSL2HLSL_DXIL_SAMPLER_STATE;
                require(sampler || binding.resource_class == GLSL2HLSL_DXIL_SRV, "unexpected resource class");
                range = {sampler ? D3D12_DESCRIPTOR_RANGE_TYPE_SAMPLER : D3D12_DESCRIPTOR_RANGE_TYPE_SRV, 1, binding.binding, binding.space, 0};
                parameter.ParameterType = D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;
                parameter.DescriptorTable = {1, &range};
                if (sampler) ++sampler_count; else ++srv_count;
            }
        }
        D3D12_ROOT_SIGNATURE_DESC root_desc{};
        root_desc.NumParameters = static_cast<UINT>(parameters.size());
        root_desc.pParameters = parameters.data();
        root_desc.Flags = D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT;
        ComPtr<ID3DBlob> blob, errors;
        if (heap_mode) {
            D3D12_VERSIONED_ROOT_SIGNATURE_DESC versioned{};
            versioned.Version = D3D_ROOT_SIGNATURE_VERSION_1_1;
            versioned.Desc_1_1.Flags = static_cast<D3D12_ROOT_SIGNATURE_FLAGS>(root_desc.Flags | execution.root_flags);
            check(D3D12SerializeVersionedRootSignature(&versioned, &blob, &errors));
        } else check(D3D12SerializeRootSignature(&root_desc, D3D_ROOT_SIGNATURE_VERSION_1, &blob, &errors));
        ComPtr<ID3D12RootSignature> root;
        check(device->CreateRootSignature(0, blob->GetBufferPointer(), blob->GetBufferSize(), IID_PPV_ARGS(&root)));

        std::vector<D3D12_INPUT_ELEMENT_DESC> input;
        std::vector<const glsl2hlsl_dxil_signature *> input_signatures;
        std::vector<UINT> target_indices;
        for (size_t index = 0; index < reflection.signature_count; ++index) {
            const auto &signature = reflection.signatures[index];
            if (signature.stage == 1 && signature.is_input && signature.semantic == 0) {
                const DXGI_FORMAT floating[] = {DXGI_FORMAT_UNKNOWN, DXGI_FORMAT_R32_FLOAT, DXGI_FORMAT_R32G32_FLOAT, DXGI_FORMAT_R32G32B32_FLOAT, DXGI_FORMAT_R32G32B32A32_FLOAT};
                const DXGI_FORMAT signed_int[] = {DXGI_FORMAT_UNKNOWN, DXGI_FORMAT_R32_SINT, DXGI_FORMAT_R32G32_SINT, DXGI_FORMAT_R32G32B32_SINT, DXGI_FORMAT_R32G32B32A32_SINT};
                const DXGI_FORMAT unsigned_int[] = {DXGI_FORMAT_UNKNOWN, DXGI_FORMAT_R32_UINT, DXGI_FORMAT_R32G32_UINT, DXGI_FORMAT_R32G32B32_UINT, DXGI_FORMAT_R32G32B32A32_UINT};
                const auto format = (signature.scalar == 4 ? floating : signature.scalar == 2 ? signed_int : unsigned_int)[signature.columns];
                input.push_back({signature.name, signature.semantic_index, format, 0, static_cast<UINT>(input.size()*16), D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0});
                input_signatures.push_back(&signature);
            }
            if (signature.stage == 2 && !signature.is_input && signature.semantic == 16) target_indices.push_back(signature.semantic_index);
        }
        const UINT target_count = target_indices.empty() ? 0 : *std::max_element(target_indices.begin(), target_indices.end()) + 1;
        D3D12_GRAPHICS_PIPELINE_STATE_DESC pipeline_desc{};
        pipeline_desc.pRootSignature = root.Get();
        pipeline_desc.VS = {program.vertex().data(), program.vertex().size()};
        pipeline_desc.PS = {program.fragment().data(), program.fragment().size()};
        std::string reference_vs, reference_ps;
        if (reference_coordinates && name.starts_with("gl-")) {
            reference_vs = read_source("zig-out/dxil/m2/reference-coordinates.vert.dxil");
            reference_ps = read_source("zig-out/dxil/m2/reference-coordinates.frag.dxil");
            pipeline_desc.VS = {reference_vs.data(), reference_vs.size()};
            pipeline_desc.PS = {reference_ps.data(), reference_ps.size()};
        }
        pipeline_desc.InputLayout = {input.data(), static_cast<UINT>(input.size())};
        pipeline_desc.SampleMask = UINT_MAX;
        pipeline_desc.SampleDesc.Count = 1;
        pipeline_desc.RasterizerState.FillMode = D3D12_FILL_MODE_SOLID;
        pipeline_desc.RasterizerState.CullMode = draw.cull_back ? D3D12_CULL_MODE_BACK : D3D12_CULL_MODE_NONE;
        pipeline_desc.RasterizerState.FrontCounterClockwise = BOOL(prepared.front_counter_clockwise);
        pipeline_desc.RasterizerState.DepthClipEnable = TRUE;
        pipeline_desc.PrimitiveTopologyType = D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
        pipeline_desc.NumRenderTargets = target_count;
        pipeline_desc.DSVFormat = DXGI_FORMAT_D32_FLOAT;
        pipeline_desc.DepthStencilState.DepthEnable = draw.depth_test;
        pipeline_desc.DepthStencilState.DepthWriteMask = D3D12_DEPTH_WRITE_MASK_ALL;
        pipeline_desc.DepthStencilState.DepthFunc = D3D12_COMPARISON_FUNC_ALWAYS;
        for (unsigned index = 0; index < target_count; ++index) {
            pipeline_desc.RTVFormats[index] = DXGI_FORMAT_R32G32B32A32_FLOAT;
            pipeline_desc.BlendState.RenderTarget[index].RenderTargetWriteMask = D3D12_COLOR_WRITE_ENABLE_ALL;
        }
        ComPtr<ID3D12PipelineState> pipeline;
        const auto pso_start = std::chrono::steady_clock::now();
        const HRESULT pso_status = device->CreateGraphicsPipelineState(&pipeline_desc, IID_PPV_ARGS(&pipeline));
        if (FAILED(pso_status)) {
            for (UINT64 index = 0; index < messages->GetNumStoredMessages(); ++index) {
                SIZE_T size = 0;
                check(messages->GetMessage(index, nullptr, &size));
                std::vector<char> storage(size);
                auto *message = reinterpret_cast<D3D12_MESSAGE *>(storage.data());
                check(messages->GetMessage(index, message, &size));
                std::cerr << message->pDescription << '\n';
            }
            check(pso_status);
        }
        const auto pso_us = std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now()-pso_start).count();
        ensure_no_compiler();

        ComPtr<ID3D12CommandAllocator> allocator;
        ComPtr<ID3D12GraphicsCommandList> commands;
        check(device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, IID_PPV_ARGS(&allocator)));
        check(device->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, allocator.Get(), pipeline.Get(), IID_PPV_ARGS(&commands)));
        std::vector<ComPtr<ID3D12Resource>> retained;
        ComPtr<ID3D12DescriptorHeap> srv_heap, sampler_heap;
        std::vector<ID3D12DescriptorHeap *> shader_heaps;
        if (srv_count) { srv_heap = descriptors(D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV, srv_count, true); shader_heaps.push_back(srv_heap.Get()); }
        if (sampler_count) { sampler_heap = descriptors(D3D12_DESCRIPTOR_HEAP_TYPE_SAMPLER, sampler_count, true); shader_heaps.push_back(sampler_heap.Get()); }
        if (!shader_heaps.empty()) commands->SetDescriptorHeaps(static_cast<UINT>(shader_heaps.size()), shader_heaps.data());
        commands->SetGraphicsRootSignature(root.Get());
        unsigned srv_index = 0, sampler_index = 0;
        for (UINT index = 0; index < reflection.binding_count; ++index) {
            const auto &binding = reflection.bindings[index];
            if (binding.resource_class == GLSL2HLSL_DXIL_CBUFFER) {
                std::vector<std::uint32_t> words((binding.size + 255) / 256 * 64);
                if (binding.space == 1) std::memcpy(words.data(), prepared.constants, sizeof(prepared.constants));
                else for (size_t uniform_index = 0; uniform_index < reflection.uniform_count; ++uniform_index) {
                    const auto &uniform = reflection.uniforms[uniform_index];
                    const auto found = draw.uniforms.find(uniform.name);
                    if (found == draw.uniforms.end()) continue;
                    const auto &source = found->second;
                    if (uniform.type.array_length) {
                        const unsigned components = uniform.type.rows * uniform.type.columns;
                        require(source.size() == components * uniform.type.array_length, "uniform array shape mismatch");
                        for (unsigned element = 0; element < uniform.type.array_length; ++element)
                            std::memcpy(words.data()+uniform.offset/4+element*uniform.array_stride/4, source.data()+element*components, components*4);
                    } else if (uniform.type.columns > 1) {
                        require(source.size() == uniform.type.rows * uniform.type.columns, "uniform matrix shape mismatch");
                        for (unsigned column = 0; column < uniform.type.columns; ++column)
                            std::memcpy(words.data()+uniform.offset/4+column*uniform.matrix_stride/4, source.data()+column*uniform.type.rows, uniform.type.rows*4);
                    } else {
                        require(source.size()*4 <= uniform.size, "uniform upload exceeds reflected size");
                        std::memcpy(words.data()+uniform.offset/4, source.data(), source.size()*4);
                    }
                }
                retained.push_back(upload(words.data(), words.size()*4));
                if (heap_mode) {
                    D3D12_CONSTANT_BUFFER_VIEW_DESC view{retained.back()->GetGPUVirtualAddress(), static_cast<UINT>(words.size()*4)};
                    auto cpu = srv_heap->GetCPUDescriptorHandleForHeapStart();
                    cpu.ptr += execution.heap_bindings[index].heap_index * device->GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
                    device->CreateConstantBufferView(&view, cpu);
                } else commands->SetGraphicsRootConstantBufferView(index, retained.back()->GetGPUVirtualAddress());
            } else if (binding.resource_class == GLSL2HLSL_DXIL_SRV) {
                const auto desc = texture_desc(DXGI_FORMAT_R32G32B32A32_FLOAT, 4, D3D12_RESOURCE_FLAG_NONE);
                auto texture = resource(desc, D3D12_HEAP_TYPE_DEFAULT, D3D12_RESOURCE_STATE_COPY_DEST);
                D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprints[4];
                UINT64 size;
                device->GetCopyableFootprints(&desc, 0, 4, 0, footprints, nullptr, nullptr, &size);
                std::vector<char> data(size);
                for (unsigned mip = 0; mip < 4; ++mip) for (unsigned row = 0; row < (extent >> mip); ++row) for (unsigned column = 0; column < (extent >> mip); ++column) {
                    const auto value = texel(binding.binding, mip, column, row);
                    std::memcpy(data.data()+footprints[mip].Offset+row*footprints[mip].Footprint.RowPitch+column*sizeof(Color), value.data(), sizeof(Color));
                }
                auto source_buffer = upload(data.data(), data.size());
                for (unsigned mip = 0; mip < 4; ++mip) {
                    D3D12_TEXTURE_COPY_LOCATION destination{}, source{};
                    destination.pResource = texture.Get(); destination.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX; destination.SubresourceIndex = mip;
                    source.pResource = source_buffer.Get(); source.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT; source.PlacedFootprint = footprints[mip];
                    commands->CopyTextureRegion(&destination, 0, 0, 0, &source, nullptr);
                }
                const auto barrier = transition(texture.Get(), D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE | D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
                commands->ResourceBarrier(1, &barrier);
                D3D12_SHADER_RESOURCE_VIEW_DESC view{};
                view.Format = desc.Format; view.ViewDimension = D3D12_SRV_DIMENSION_TEXTURE2D;
                view.Shader4ComponentMapping = D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING; view.Texture2D.MipLevels = 4;
                auto cpu = srv_heap->GetCPUDescriptorHandleForHeapStart(); auto gpu = srv_heap->GetGPUDescriptorHandleForHeapStart();
                const unsigned stride = device->GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
                const auto slot = heap_mode ? execution.heap_bindings[index].heap_index : srv_index++;
                cpu.ptr += slot*stride; gpu.ptr += slot*stride;
                device->CreateShaderResourceView(texture.Get(), &view, cpu);
                if (!heap_mode) commands->SetGraphicsRootDescriptorTable(index, gpu);
                retained.push_back(std::move(texture)); retained.push_back(std::move(source_buffer));
            } else {
                D3D12_SAMPLER_DESC sampler{};
                sampler.Filter = D3D12_FILTER_MIN_MAG_MIP_POINT;
                sampler.AddressU = sampler.AddressV = sampler.AddressW = D3D12_TEXTURE_ADDRESS_MODE_CLAMP;
                sampler.MaxLOD = D3D12_FLOAT32_MAX;
                sampler.ComparisonFunc = D3D12_COMPARISON_FUNC_ALWAYS;
                auto cpu = sampler_heap->GetCPUDescriptorHandleForHeapStart(); auto gpu = sampler_heap->GetGPUDescriptorHandleForHeapStart();
                const unsigned stride = device->GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_SAMPLER);
                const auto slot = heap_mode ? execution.heap_bindings[index].heap_index : sampler_index++;
                cpu.ptr += slot*stride; gpu.ptr += slot*stride;
                device->CreateSampler(&sampler, cpu);
                if (!heap_mode) commands->SetGraphicsRootDescriptorTable(index, gpu);
            }
        }

        auto rtv_heap = descriptors(D3D12_DESCRIPTOR_HEAP_TYPE_RTV, std::max(target_count, 1u), false);
        auto dsv_heap = descriptors(D3D12_DESCRIPTOR_HEAP_TYPE_DSV, 1, false);
        std::vector<ComPtr<ID3D12Resource>> targets;
        std::vector<D3D12_CPU_DESCRIPTOR_HANDLE> rtvs;
        for (unsigned index = 0; index < target_count; ++index) {
            targets.push_back(resource(texture_desc(DXGI_FORMAT_R32G32B32A32_FLOAT, 1, D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET), D3D12_HEAP_TYPE_DEFAULT, D3D12_RESOURCE_STATE_RENDER_TARGET));
            auto rtv = rtv_heap->GetCPUDescriptorHandleForHeapStart();
            rtv.ptr += index*device->GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_RTV);
            device->CreateRenderTargetView(targets.back().Get(), nullptr, rtv);
            commands->ClearRenderTargetView(rtv, clear_color.data(), 0, nullptr); rtvs.push_back(rtv);
        }
        auto depth = resource(texture_desc(DXGI_FORMAT_D32_FLOAT, 1, D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL), D3D12_HEAP_TYPE_DEFAULT, D3D12_RESOURCE_STATE_DEPTH_WRITE);
        const auto dsv = dsv_heap->GetCPUDescriptorHandleForHeapStart();
        device->CreateDepthStencilView(depth.Get(), nullptr, dsv);
        commands->ClearDepthStencilView(dsv, D3D12_CLEAR_FLAG_DEPTH, 0.9375f, 0, 0, nullptr);
        commands->OMSetRenderTargets(target_count, rtvs.data(), FALSE, &dsv);
        D3D12_VIEWPORT viewport{};
        std::memcpy(&viewport, prepared.viewport, sizeof(viewport));
        const D3D12_RECT scissor{0, 0, extent, extent};
        commands->RSSetViewports(1, &viewport); commands->RSSetScissorRects(1, &scissor);
        std::vector<Color> vertices(3*input.size());
        for (size_t attribute_index = 0; attribute_index < input.size(); ++attribute_index) {
            const auto found = draw.attributes.find(input_signatures[attribute_index]->semantic_index);
            require(found != draw.attributes.end(), "missing vertex attribute");
            for (unsigned corner = 0; corner < 3; ++corner)
                vertices[corner*input.size()+attribute_index] = found->second[draw.clockwise_mesh && corner ? 3-corner : corner];
        }
        auto vertex_buffer = upload(vertices.data(), vertices.size()*sizeof(Color));
        const D3D12_VERTEX_BUFFER_VIEW vertex_view{vertex_buffer->GetGPUVirtualAddress(), static_cast<UINT>(vertices.size()*sizeof(Color)), static_cast<UINT>(input.size()*sizeof(Color))};
        if (!input.empty()) commands->IASetVertexBuffers(0, 1, &vertex_view);
        commands->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
        commands->DrawInstanced(3, draw.instances, 0, prepared.start_instance_location);

        struct Readback { ComPtr<ID3D12Resource> buffer; D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprint; UINT64 size; };
        std::vector<Readback> readbacks;
        auto copy = [&](ID3D12Resource *source, D3D12_RESOURCE_STATES before) {
            Readback value{};
            const auto desc = source->GetDesc();
            device->GetCopyableFootprints(&desc, 0, 1, 0, &value.footprint, nullptr, nullptr, &value.size);
            value.buffer = resource(buffer_desc(value.size), D3D12_HEAP_TYPE_READBACK, D3D12_RESOURCE_STATE_COPY_DEST);
            const auto barrier = transition(source, before, D3D12_RESOURCE_STATE_COPY_SOURCE);
            commands->ResourceBarrier(1, &barrier);
            D3D12_TEXTURE_COPY_LOCATION source_location{}, destination{};
            source_location.pResource = source; source_location.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
            destination.pResource = value.buffer.Get(); destination.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT; destination.PlacedFootprint = value.footprint;
            commands->CopyTextureRegion(&destination, 0, 0, 0, &source_location, nullptr);
            readbacks.push_back(std::move(value));
        };
        for (const auto &target : targets) copy(target.Get(), D3D12_RESOURCE_STATE_RENDER_TARGET);
        copy(depth.Get(), D3D12_RESOURCE_STATE_DEPTH_WRITE);
        check(commands->Close());
        ID3D12CommandList *lists[] = {commands.Get()}; queue->ExecuteCommandLists(1, lists);
        ComPtr<ID3D12Fence> fence;
        check(device->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(&fence))); check(queue->Signal(fence.Get(), 1));
        HANDLE event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
        require(event != nullptr, "cannot create fence event");
        const HRESULT event_status = fence->SetEventOnCompletion(1, event);
        const DWORD wait = SUCCEEDED(event_status) ? WaitForSingleObject(event, 10000) : WAIT_FAILED;
        CloseHandle(event); check(event_status); require(wait == WAIT_OBJECT_0, "GPU timed out");
        std::vector<float> pixels;
        for (unsigned index = 0; index < readbacks.size(); ++index) {
            auto &readback = readbacks[index];
            void *mapped; const D3D12_RANGE range{0, static_cast<SIZE_T>(readback.size)};
            check(readback.buffer->Map(0, &range, &mapped));
            for (unsigned row = 0; row < extent; ++row) for (unsigned column = 0; column < extent; ++column) {
                const bool covered = !draw.no_coverage && column+0.5f >= viewport.TopLeftX && column+0.5f < viewport.TopLeftX+viewport.Width && row+0.5f >= viewport.TopLeftY && row+0.5f < viewport.TopLeftY+viewport.Height;
                const auto *actual = reinterpret_cast<const float *>(static_cast<const char *>(mapped)+readback.footprint.Offset+row*readback.footprint.Footprint.RowPitch);
                if (index == target_count) {
                    pixels.push_back(actual[column]);
                    if (!draw.expected_depth) continue;
                    const float expected = covered ? draw.expected_depth(column, row) : 0.9375f;
                    require(std::isfinite(actual[column]) && std::abs(actual[column]-expected)<0.00002f, name+": depth mismatch at "+std::to_string(column)+","+std::to_string(row));
                } else {
                    for (unsigned channel = 0; channel < 4; ++channel) pixels.push_back(actual[column*4+channel]);
                    const auto expected = covered ? draw.expected(column, row, index) : clear_color;
                    for (unsigned channel = 0; channel < 4; ++channel) if (!std::isfinite(actual[column*4+channel]) || std::abs(actual[column*4+channel]-expected[channel])>0.0002f) {
                        std::cerr << "pixel=" << column << ',' << row << " target=" << index << " channel=" << channel << " actual=" << actual[column*4+channel] << " expected=" << expected[channel] << '\n';
                        throw std::runtime_error(name+": pixel mismatch");
                    }
                }
            }
            D3D12_RANGE empty{}; readback.buffer->Unmap(0, &empty);
        }
        if (modern_target || optimize_programs) {
            const auto found = baseline_pixels.find(name);
            require(found != baseline_pixels.end() && found->second.size() == pixels.size(), "missing SM6.5 pixel baseline");
            for (size_t index = 0; index < pixels.size(); ++index)
                require(std::isfinite(pixels[index]) && std::abs(pixels[index]-found->second[index]) < 0.0002f, name+": SM6.5/6.9 pixel or depth mismatch");
        } else baseline_pixels[name] = std::move(pixels);
        for (UINT64 index = 0; index < messages->GetNumStoredMessages(); ++index) {
            SIZE_T size = 0; check(messages->GetMessage(index, nullptr, &size)); std::vector<char> storage(size);
            auto *message = reinterpret_cast<D3D12_MESSAGE *>(storage.data()); check(messages->GetMessage(index, message, &size));
            if (message->Severity <= D3D12_MESSAGE_SEVERITY_ERROR) { std::cerr << message->pDescription << '\n'; throw std::runtime_error("D3D12 debug error"); }
        }
        ensure_no_compiler();
        std::cout << "passed=" << name << " pixels=" << extent*extent << " pso_us=" << pso_us << " compiler_dlls=absent\n";
    }
};

static constexpr auto basic_vertex = "layout(location=0) in vec4 p; void main(){gl_Position=p;}";
static constexpr auto basic_fragment = "out vec4 c; void main(){c=vec4(0.25,0.5,0.75,1);}";

static void acceptance(Renderer &renderer) {
    auto basic = compile(basic_vertex, basic_fragment, true);
    Draw draw;
    draw.expected = [](unsigned, unsigned, unsigned) { return Color{0.25f, 0.5f, 0.75f, 1}; };
    renderer.run("native-source", basic, draw);

    auto globals=compile(basic_vertex,"const float Z=0.25;const mat2 A=mat2(Z,0,0,2*Z);out vec4 c;void main(){c=vec4(A*vec2(1),Z,1);}",true);
    Draw global_draw;global_draw.expected=[](unsigned,unsigned,unsigned){return Color{0.25f,0.5f,0.25f,1};};
    renderer.run("global-initializer-declaration-order",globals,global_draw);
    auto repeated=compile(basic_vertex,"uniform float a;out vec4 c;void main(){float v=a;float x=v*v+v*v+v*v+v*v;c=vec4(x);}",true);
    Draw repeated_draw;repeated_draw.floats("a",{0.25f});
    repeated_draw.expected=[](unsigned,unsigned,unsigned){return Color{0.25f,0.25f,0.25f,0.25f};};
    renderer.run("safe-cse-captured-input",repeated,repeated_draw);

    auto flow = compile(basic_vertex, R"(
        uniform int count; out vec4 c;
        float helper(inout float a, out float b) { a += 2.0; b=a*3.0; if(a>4.0) return b; return a; }
        void main() {
            int side=0; bool a=false && (side++ > 0); bool b=true || (side++ > 0);
            float total=0.0;
            for(int i=0;i<count;i++){ if(i==1)continue; if(i==5)break; total+=float(i); }
            int j=0; while(j<2){ total+=0.5; j++; }
            do { total+=0.25; j--; } while(j>0);
            switch(count){ case 6: total+=2.0; case 7: total+=3.0; break; default: total=-100.0; }
            float x=3.0; float y; float z=helper(x,y);
            c=vec4(total, x+y+z, float(side), (a || !b) ? -1.0 : 1.0);
        })", true);
    draw.integer("count", 6);
    draw.expected = [](unsigned, unsigned, unsigned) { return Color{15.5f, 35, 0, 1}; };
    renderer.run("ssa-control-copyout", flow, draw);

    auto vectors = compile(basic_vertex, read_source("tests/dxil/vectors.frag"), true);
    Draw vector_draw;
    vector_draw.floats("a", {0.1f,0.2f,0.3f,0.4f}); vector_draw.floats("b", {0.5f,0.6f,0.7f,0.8f});
    vector_draw.uniforms["integers"] = {1,2,3,4}; vector_draw.uniforms["shifts"] = {0,1,2,3};
    vector_draw.expected = [](unsigned,unsigned,unsigned) { return Color{0.9f,0.12f,15,0.6f}; };
    require(!modern_target || vectors.execution_info().native_vectors, "native vector arithmetic missing from SM6.9 output");
    renderer.run("native-vectors-float-int-2-3-4", vectors, vector_draw);

    auto matrices = compile(basic_vertex, R"(
        uniform mat3 matrix; uniform float weights[3]; uniform vec3 vector_value; uniform float tail;
        out vec4 c;
        void main(){ vec3 a=matrix*vector_value; vec3 b=vector_value*matrix;
            mat3 product=matrix*mat3(2.0); c=vec4(a.x+b.y+product[2][1],weights[0]+weights[1]*2.0+weights[2]*3.0,tail,1); }
        )", true);
    Draw matrix_draw;
    matrix_draw.floats("matrix", {1,2,3,4,6,5,9,8,7}); matrix_draw.floats("vector_value", {2,3,4});
    matrix_draw.floats("weights", {0.125f,0.25f,0.75f}); matrix_draw.floats("tail", {0.625f});
    matrix_draw.expected = [](unsigned, unsigned, unsigned) { return Color{112, 2.875f, 0.625f, 1}; };
    renderer.run("matrix-layout-row-column", matrices, matrix_draw);

    auto resources = compile(basic_vertex, R"(
        uniform sampler2D a_tex; uniform sampler2D b_tex; layout(location=0) out vec4 first; layout(location=1) out vec4 second;
        void main(){ first=textureLod(a_tex,vec2(0.3,0.6),1.0); second=texelFetch(b_tex,ivec2(3,5),0); }
        )", true);
    Draw resource_draw;
    resource_draw.expected = [](unsigned, unsigned, unsigned target) { return target ? texel(1,0,3,5) : sample(0,0.3f,0.6f,1); };
    renderer.run("two-textures-mips-mrt", resources, resource_draw);

    const auto identity = {1.0f,0.0f,0.0f,0.0f,0.0f,1.0f,0.0f,0.0f,0.0f,0.0f,1.0f,0.0f,0.0f,0.0f,0.0f,1.0f};
    for (bool showcase : {false,true}) {
        const auto vertex_source = read_source(showcase ? "examples/showcase.vert" : "examples/triangle.vert");
        const auto fragment_source = read_source(showcase ? "examples/showcase.frag" : "examples/triangle.frag");
        auto program = compile(vertex_source, fragment_source);
        Draw corpus;
        corpus.floats("u_mvp", identity); corpus.floats(showcase ? "u_normal" : "u_model", identity); corpus.floats("u_light_dir", {0,0,1});
        if (showcase) {
            for (auto &vertex : corpus.attributes[0]) { vertex[0] *= 0.5f; vertex[1] *= 0.5f; }
            corpus.attributes[1] = constant_attribute({0,0,1,0});
        } else {
            corpus.attributes[1] = {{{0,0,0,0},{0,2,0,0},{2,0,0,0}}};
            corpus.attributes[2] = constant_attribute({0,0,1,0});
        }
        corpus.expected = [showcase](unsigned x, unsigned y, unsigned) {
            float u=(float(x)+0.5f)/float(extent), v=1-(float(y)+0.5f)/float(extent);
            if (showcase) { u=u*0.5f+0.25f; v=v*0.5f+0.25f; }
            auto value=sample(0,u,v);
            if (showcase) {
                if (value[3]<0.1f) return clear_color;
                for (unsigned channel=0;channel<3;++channel) value[channel]=value[channel]*0.9f+0.1f;
                value[0]+=std::floor(u*4)*0.25f; value[0]-=std::floor(value[0]);
            }
            return value;
        };
        renderer.run(showcase ? "corpus-showcase" : "corpus-triangle",program,corpus);
    }

    auto features_vertex = compile(read_source("tests/shaders/features.vert"), "in vec2 v_uv; out vec4 c; void main(){c=vec4(v_uv,0.75,1);}");
    Draw rotated;
    rotated.floats("u_mvp",identity);
    rotated.attributes[0] = {{{-1,1,0,1},{3,1,0,1},{-1,-3,0,1}}};
    rotated.expected=[](unsigned x,unsigned y,unsigned){ return Color{2*(float(y)+0.5f)/float(extent)-1,2*(float(x)+0.5f)/float(extent)-1,0.75f,1}; };
    renderer.run("corpus-features-vertex",features_vertex,rotated);

    constexpr auto uv_vertex = "layout(location=0) in vec4 p; layout(location=1) in vec2 uv; out vec2 v_uv; void main(){gl_Position=p;v_uv=uv;}";
    constexpr auto color_vertex = "layout(location=0) in vec4 p; layout(location=1) in vec2 uv; layout(location=2) in vec3 color; out vec2 v_uv; out vec3 v_color; void main(){gl_Position=p;v_uv=uv;v_color=color;}";
    auto features_fragment=compile(color_vertex,read_source("tests/shaders/features.frag"));
    Draw features;
    features.attributes[1]=constant_attribute({0.35f,0.6f,0,0}); features.attributes[2]=constant_attribute({0.3f,0.4f,0.5f,0});
    features.floats("u_tint",{0.2f,0.3f,0.4f,0.25f}); features.floats("u_weights",{1,2,3,4});
    features.expected=[](unsigned,unsigned,unsigned){ const auto first=sample(0,-0.3f,0.2f); const auto second=texel(1,0,5,9); return Color{0.3f*0.75f+first[0]*0.25f+second[0],0.4f*0.75f+first[1]*0.25f+second[1],0.5f*0.75f+first[2]*0.25f+second[2],1}; };
    renderer.run("corpus-features-fragment",features_fragment,features);
    features.floats("u_weights",{30,30,30,30}); features.expected=[](unsigned,unsigned,unsigned){return clear_color;};
    renderer.run("corpus-features-discard",features_fragment,features);

    auto structures=compile(uv_vertex,read_source("tests/shaders/structs.frag"));
    Draw structure;
    structure.attributes[1]=constant_attribute({0.2f,0.7f,0,0}); structure.floats("u_material.albedo",{0.1f,0.3f,0.7f}); structure.floats("u_material.roughness",{0.4f}); structure.floats("u_tint",{0.6f,0.2f,0.4f,0.8f});
    for (int mode : {0,1,2}) {
        structure.integer("u_mode",mode);
        structure.expected=[mode](unsigned,unsigned,unsigned){return mode==0 ? Color{0.1f,0.3f,0.7f,1} : mode==1 ? Color{0.6f,0.2f,0.4f,1} : Color{1,1,1,1};};
        renderer.run("corpus-structs-"+std::to_string(mode),structures,structure);
    }
    auto legacy=compile(uv_vertex,read_source("tests/shaders/legacy.frag"));
    for (float u : {0.03f,0.3f}) {
        Draw legacy_draw; legacy_draw.attributes[1]=constant_attribute({u,0.6f,0,0});
        legacy_draw.expected=[u](unsigned,unsigned,unsigned){auto value=sample(0,u,0.6f);return value[3]<0.5f ? clear_color : value;};
        renderer.run("corpus-legacy-"+std::to_string(u),legacy,legacy_draw);
    }
    auto builtin_vertex=compile(read_source("tests/shaders/builtins.vert"),basic_fragment);
    Draw degenerate; degenerate.floats("u_mvp",identity); degenerate.no_coverage=true; degenerate.expected=[](unsigned,unsigned,unsigned){return clear_color;};
    renderer.run("corpus-builtins-vertex-degenerate",builtin_vertex,degenerate);
    auto builtin_fragment=compile(basic_vertex,read_source("tests/shaders/builtins.frag"));
    Draw builtin_draw; builtin_draw.depth_test=true;
    builtin_draw.expected=[](unsigned,unsigned,unsigned){return Color{0,0,0,0};}; builtin_draw.expected_depth=[](unsigned,unsigned){return 0.5f;};
    renderer.run("corpus-builtins-fragment-back",builtin_fragment,builtin_draw);
    builtin_draw.clockwise_mesh=true;
    builtin_draw.expected=[](unsigned,unsigned,unsigned){return sample(0,0,0);};
    renderer.run("corpus-builtins-fragment-front",builtin_fragment,builtin_draw);

    auto coordinates=compile(R"(
        layout(location=0) in vec4 p; flat out int instance_id; flat out int vertex_id;
        void main(){gl_Position=p;instance_id=gl_InstanceID;vertex_id=gl_VertexID;}
        )", R"(
        flat in int instance_id; flat in int vertex_id; layout(location=0) out vec4 first; layout(location=1) out vec4 second;
        void main(){first=vec4(gl_FragCoord.xyz/vec3(16,16,1),gl_FrontFacing ? 1.0 : 0.0);
            second=vec4(float(instance_id),gl_FragCoord.w,float(vertex_id),1);gl_FragDepth=gl_FragCoord.z;}
        )");
    const auto coordinate_directory = std::string("zig-out/dxil/") + (direct_heap ? "m3-heap" : modern_target ? "m3" : "m2");
    std::ofstream(coordinate_directory+"/coordinates.vert.dxil",std::ios::binary).write(reinterpret_cast<const char *>(coordinates.vertex().data()),coordinates.vertex().size());
    std::ofstream(coordinate_directory+"/coordinates.frag.dxil",std::ios::binary).write(reinterpret_cast<const char *>(coordinates.fragment().data()),coordinates.fragment().size());
    unsigned combination=0;
    for(unsigned origin : {0u,1u}) for(unsigned clip : {0u,1u}) for(auto range : {std::array{0.0f,1.0f},std::array{0.2f,0.8f},std::array{0.8f,0.2f}})
    for(unsigned winding : {0u,1u}) for(unsigned base : {0u,7u}) for(bool offset : {false,true}) {
        Draw coordinate;
        coordinate.attributes=fullscreen(0.5f,2);
        coordinate.instances=2; coordinate.depth_test=true;
        coordinate.state.clip_origin=origin; coordinate.state.clip_depth=clip; coordinate.state.winding=winding; coordinate.state.base_instance=base;
        coordinate.state.depth_near=range[0]; coordinate.state.depth_far=range[1];
        if(offset){coordinate.state.viewport_x=2;coordinate.state.viewport_y=3;coordinate.state.viewport_width=10;coordinate.state.viewport_height=8;}
        const float depth_value=range[0]+(range[1]-range[0])*(clip==0 ? 0.625f : 0.25f);
        coordinate.expected=[winding,depth_value](unsigned x,unsigned y,unsigned target){return target ? Color{1,0.5f,0,1} : Color{(float(x)+0.5f)/16,(16-float(y)-0.5f)/16,depth_value,float(winding)};};
        coordinate.expected_depth=[depth_value](unsigned,unsigned){return depth_value;};
        renderer.run("gl-state-"+std::to_string(combination++),coordinates,coordinate);
    }
    require(combination==96,"coordinate matrix count");
    for (unsigned clip : {0u,1u}) for (bool reverse : {false,true}) for (float z : {-3.0f,3.0f}) {
        Draw clipped; clipped.state.clip_depth=clip; if(reverse){clipped.state.depth_near=0.8f;clipped.state.depth_far=0.2f;}
        clipped.attributes=fullscreen(z,1); clipped.no_coverage=true; clipped.expected=[](unsigned,unsigned,unsigned){return clear_color;};
        renderer.run("gl-outside-clip-"+std::to_string(clip)+"-"+std::to_string(reverse)+"-"+std::to_string(z),coordinates,clipped);
    }
    for (unsigned origin : {0u,1u}) for(unsigned winding : {0u,1u}) {
        Draw cull; cull.state.clip_origin=origin;cull.state.winding=winding;cull.cull_back=true;cull.no_coverage=winding==0;
        cull.expected=[](unsigned,unsigned,unsigned target){return target ? Color{0,1,0,1} : Color{0,0,0.5f,1};};
        if(winding) cull.expected=[](unsigned x,unsigned y,unsigned target){return target ? Color{0,1,0,1} : Color{(float(x)+0.5f)/16,(16-float(y)-0.5f)/16,0.5f,1};};
        renderer.run("gl-cull-"+std::to_string(origin)+"-"+std::to_string(winding),coordinates,cull);
    }
    Draw negative_w; negative_w.attributes=fullscreen(0,-1);negative_w.no_coverage=true;negative_w.expected=[](unsigned,unsigned,unsigned){return clear_color;};
    renderer.run("gl-negative-w",coordinates,negative_w);
    Draw zero_w; zero_w.attributes=fullscreen(0,0);zero_w.no_coverage=true;zero_w.expected=[](unsigned,unsigned,unsigned){return clear_color;};
    renderer.run("gl-zero-w",coordinates,zero_w);
}

static void minecraft_acceptance(Renderer &renderer) {
    const auto directory = std::string("zig-out/m4/minecraft/assets/minecraft/shaders/");
    const auto identity = {1.0f,0.0f,0.0f,0.0f,0.0f,1.0f,0.0f,0.0f,0.0f,0.0f,1.0f,0.0f,0.0f,0.0f,0.0f,1.0f};
    auto color_program = compile(read_source((directory+"core/position_color.vsh").c_str()), read_source((directory+"core/position_color.fsh").c_str()));
    Draw color;
    color.attributes.clear();
    color.attributes[0]=constant_attribute({0.2f,0.4f,0.8f,1});
    color.attributes[1]=fullscreen().at(0);
    color.floats("ModelViewMat",identity); color.floats("ProjMat",identity);
    color.floats("ColorModulator",{0.5f,0.75f,0.25f,1});
    color.expected=[](unsigned,unsigned,unsigned){return Color{0.1f,0.3f,0.2f,1};};
    color.depth_test=true; color.expected_depth=[](unsigned,unsigned){return 0.5f;};
    renderer.run("minecraft-1.21.4-position-color",color_program,color);

    const auto fog_source=read_source((directory+"include/fog.glsl").c_str());
    constexpr std::string_view fog_name="assets/minecraft/shaders/include/fog.glsl";
    const glsl2hlsl_dxil_file files[]={{{fog_name.data(),fog_name.size()},{fog_source.data(),fog_source.size()}}};
    auto fog_program=compile(read_source((directory+"core/position.vsh").c_str()),read_source((directory+"core/position.fsh").c_str()),false,files);
    for(int shape : {0,1}) {
        Draw fog;
        fog.floats("ModelViewMat",identity);fog.floats("ProjMat",identity);fog.integer("FogShape",shape);
        fog.floats("ColorModulator",{0.2f,0.4f,0.8f,1});fog.floats("FogColor",{0.7f,0.3f,0.1f,0.75f});
        fog.floats("FogStart",{1});fog.floats("FogEnd",{4});
        fog.depth_test=true; fog.expected_depth=[](unsigned,unsigned){return 0.5f;};
        fog.expected=[shape](unsigned x,unsigned y,unsigned){
            const float u=(float(x)+0.5f)/float(extent), v=1-(float(y)+0.5f)/float(extent);
            const float weight=(u+v)*0.5f;
            const float distance=shape==0 ? std::sqrt(2.0f)+(std::sqrt(10.0f)-std::sqrt(2.0f))*weight : 1+2*weight;
            const float t=std::clamp((distance-1)/3,0.0f,1.0f);
            const float factor=t*t*(3-2*t)*0.75f;
            return Color{0.2f*(1-factor)+0.7f*factor,0.4f*(1-factor)+0.3f*factor,0.8f*(1-factor)+0.1f*factor,1};
        };
        renderer.run("minecraft-1.21.4-fog-shape-"+std::to_string(shape),fog_program,fog);
    }
    const auto discard_vs=read_source("zig-out/m4/iteration-runtime/Lib/Programs/Discard_VS.glsl");
    const auto discard_ps=read_source("zig-out/m4/iteration-runtime/Lib/Programs/Discard_FS.glsl");
    constexpr std::string_view vs_name="Lib/Programs/Discard_VS.glsl", ps_name="Lib/Programs/Discard_FS.glsl";
    const glsl2hlsl_dxil_file discard_files[]={
        {{vs_name.data(),vs_name.size()},{discard_vs.data(),discard_vs.size()}},
        {{ps_name.data(),ps_name.size()},{discard_ps.data(),discard_ps.size()}}
    };
    auto discard_program=compile(read_source("zig-out/m4/iteration-runtime/composite45.vsh"),read_source("zig-out/m4/iteration-runtime/composite45.fsh"),false,discard_files);
    Draw discard_draw;discard_draw.depth_test=true;discard_draw.no_coverage=true;
    discard_draw.expected=[](unsigned,unsigned,unsigned){return clear_color;};
    discard_draw.expected_depth=[](unsigned,unsigned){return 0.9375f;};
    renderer.run("iris-iterationRP-0.8.31-discard-noop",discard_program,discard_draw);
}

int main(int argc, char **argv) {
    try {
        reference_coordinates = argc > 1 && std::string_view(argv[1]) == "--reference";
        const bool m4 = argc > 1 && std::string_view(argv[1]) == "--m4";
        const bool m3 = m4 || (argc > 1 && std::string_view(argv[1]) == "--m3");
        ensure_no_compiler();
        ComPtr<ID3D12Debug> debug; check(D3D12GetDebugInterface(IID_PPV_ARGS(&debug))); debug->EnableDebugLayer();
        ComPtr<IDXGIFactory1> factory; check(CreateDXGIFactory1(IID_PPV_ARGS(&factory)));
        unsigned tested = 0;
        unsigned modern_tested = 0;
        for (UINT index = 0;; ++index) {
            ComPtr<IDXGIAdapter1> adapter; if (factory->EnumAdapters1(index, &adapter) == DXGI_ERROR_NOT_FOUND) break;
            DXGI_ADAPTER_DESC1 desc; check(adapter->GetDesc1(&desc)); if (desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) continue;
            ComPtr<ID3D12Device> device; if (FAILED(D3D12CreateDevice(adapter.Get(), D3D_FEATURE_LEVEL_12_0, IID_PPV_ARGS(&device)))) continue;
            D3D12_FEATURE_DATA_SHADER_MODEL model{D3D_SHADER_MODEL_6_5};
            if (FAILED(device->CheckFeatureSupport(D3D12_FEATURE_SHADER_MODEL, &model, sizeof(model))) || model.HighestShaderModel < D3D_SHADER_MODEL_6_5) continue;
            char name[256]; WideCharToMultiByte(CP_UTF8, 0, desc.Description, -1, name, sizeof(name), nullptr, nullptr);
            std::cout << "adapter=" << name << " debug_layer=enabled\n";
            Renderer renderer(device.Get()); acceptance(renderer); ++tested;
            if (m4) {
                minecraft_acceptance(renderer);
                optimize_programs=true; acceptance(renderer); minecraft_acceptance(renderer); optimize_programs=false;
            }
            if (m3) {
                model.HighestShaderModel = static_cast<D3D_SHADER_MODEL>(0x69);
                const bool sm69 = SUCCEEDED(device->CheckFeatureSupport(D3D12_FEATURE_SHADER_MODEL, &model, sizeof(model))) && model.HighestShaderModel >= static_cast<D3D_SHADER_MODEL>(0x69);
                D3D12_FEATURE_DATA_D3D12_OPTIONS options{};
                check(device->CheckFeatureSupport(D3D12_FEATURE_D3D12_OPTIONS, &options, sizeof(options)));
                D3D12_FEATURE_DATA_ROOT_SIGNATURE root_version{D3D_ROOT_SIGNATURE_VERSION_1_1};
                check(device->CheckFeatureSupport(D3D12_FEATURE_ROOT_SIGNATURE, &root_version, sizeof(root_version)));
                char runtime[MAX_PATH]{}; GetModuleFileNameA(GetModuleHandleW(L"D3D12Core.dll"), runtime, MAX_PATH);
                std::cout << "sm69=" << sm69 << " highest_model=0x" << std::hex << model.HighestShaderModel << std::dec << " binding_tier=" << options.ResourceBindingTier << " root_signature=" << root_version.HighestVersion << " runtime=" << runtime << '\n';
                if (!sm69) { std::cout << "m3_skipped=SM6.9 unavailable\n"; continue; }
                require(options.ResourceBindingTier >= D3D12_RESOURCE_BINDING_TIER_3 && root_version.HighestVersion >= D3D_ROOT_SIGNATURE_VERSION_1_1, "direct heap device requirements unavailable");
                modern_target = true; direct_heap = false; acceptance(renderer);
                if (m4) {
                    minecraft_acceptance(renderer); optimize_programs=true; acceptance(renderer); minecraft_acceptance(renderer); optimize_programs=false;
                }
                direct_heap = true; acceptance(renderer);
                if (m4) {
                    minecraft_acceptance(renderer); optimize_programs=true; acceptance(renderer); minecraft_acceptance(renderer); optimize_programs=false;
                }
                modern_target = false; direct_heap = false; ++modern_tested;
                std::cout << "m3_comparison=passed resources=equal interfaces=equal pixels_and_depth=equal\n";
            }
        }
        require(tested != 0, "no SM6.5 hardware adapter"); std::cout << "source_hardware_adapters_passed=" << tested << '\n';
        if (m3) { require(modern_tested != 0, "no SM6.9 hardware adapter; M3 acceptance incomplete"); std::cout << "m3_hardware_adapters_passed=" << modern_tested << '\n'; }
        if (m4) std::cout << "m4_comparison=passed minecraft=original_sources optimized_pixels_and_depth=equal\n";
        return 0;
    } catch (const std::exception &error) { std::cerr << error.what() << '\n'; return 1; }
}
