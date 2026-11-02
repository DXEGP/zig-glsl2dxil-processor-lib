#include <windows.h>
#include <d3d12.h>
#include <d3d12sdklayers.h>
#include <dxgi1_6.h>
#include <wrl/client.h>
#include <array>
#include <chrono>
#include <cmath>
#include <cstring>
#include <fstream>
#include <iostream>
#include <iterator>
#include <stdexcept>
#include <vector>

using Microsoft::WRL::ComPtr;

static void check(HRESULT status) {
    if (FAILED(status)) {
        std::cerr << "HRESULT 0x" << std::hex << static_cast<unsigned long>(status) << std::dec << "\n";
        throw std::runtime_error("D3D12 operation failed");
    }
}

static std::vector<char> read(const char *path) {
    std::ifstream file(path, std::ios::binary);
    if (!file) throw std::runtime_error("cannot read shader");
    return {std::istreambuf_iterator<char>(file), std::istreambuf_iterator<char>()};
}

static D3D12_HEAP_PROPERTIES heap(D3D12_HEAP_TYPE type) {
    D3D12_HEAP_PROPERTIES properties = {};
    properties.Type = type;
    properties.CreationNodeMask = 1;
    properties.VisibleNodeMask = 1;
    return properties;
}

static D3D12_RESOURCE_DESC buffer_desc(UINT64 size) {
    D3D12_RESOURCE_DESC desc = {};
    desc.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER;
    desc.Width = size;
    desc.Height = 1;
    desc.DepthOrArraySize = 1;
    desc.MipLevels = 1;
    desc.SampleDesc.Count = 1;
    desc.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
    return desc;
}

static void ensure_no_compiler() {
    if (GetModuleHandleW(L"dxcompiler.dll") || GetModuleHandleW(L"dxil.dll"))
        throw std::runtime_error("unexpected compiler or validator DLL in render process");
}

static void render(ID3D12Device *device, const std::vector<char> &vertex,
                   const std::vector<char> &fragment, const std::array<float, 4> &expected) {
    ComPtr<ID3D12InfoQueue> messages;
    device->QueryInterface(IID_PPV_ARGS(&messages));
    if (messages) messages->ClearStoredMessages();

    D3D12_ROOT_SIGNATURE_DESC root_desc = {};
    root_desc.Flags = D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT;
    ComPtr<ID3DBlob> root_blob, root_errors;
    check(D3D12SerializeRootSignature(&root_desc, D3D_ROOT_SIGNATURE_VERSION_1, &root_blob, &root_errors));
    ComPtr<ID3D12RootSignature> root;
    check(device->CreateRootSignature(0, root_blob->GetBufferPointer(), root_blob->GetBufferSize(), IID_PPV_ARGS(&root)));

    D3D12_INPUT_ELEMENT_DESC input = {};
    input.SemanticName = "POSITION";
    input.Format = DXGI_FORMAT_R32G32B32A32_FLOAT;
    D3D12_GRAPHICS_PIPELINE_STATE_DESC pipeline_desc = {};
    pipeline_desc.pRootSignature = root.Get();
    pipeline_desc.VS = {vertex.data(), vertex.size()};
    pipeline_desc.PS = {fragment.data(), fragment.size()};
    pipeline_desc.BlendState.RenderTarget[0].RenderTargetWriteMask = D3D12_COLOR_WRITE_ENABLE_ALL;
    pipeline_desc.SampleMask = UINT_MAX;
    pipeline_desc.RasterizerState.FillMode = D3D12_FILL_MODE_SOLID;
    pipeline_desc.RasterizerState.CullMode = D3D12_CULL_MODE_NONE;
    pipeline_desc.RasterizerState.DepthClipEnable = TRUE;
    pipeline_desc.InputLayout = {&input, 1};
    pipeline_desc.PrimitiveTopologyType = D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
    pipeline_desc.NumRenderTargets = 1;
    pipeline_desc.RTVFormats[0] = DXGI_FORMAT_R32G32B32A32_FLOAT;
    pipeline_desc.SampleDesc.Count = 1;
    ComPtr<ID3D12PipelineState> pipeline;
    const auto pso_start = std::chrono::steady_clock::now();
    check(device->CreateGraphicsPipelineState(&pipeline_desc, IID_PPV_ARGS(&pipeline)));
    const auto pso_us = std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - pso_start).count();
    ensure_no_compiler();

    const auto default_heap = heap(D3D12_HEAP_TYPE_DEFAULT);
    D3D12_RESOURCE_DESC texture_desc = {};
    texture_desc.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
    texture_desc.Width = 4;
    texture_desc.Height = 4;
    texture_desc.DepthOrArraySize = 1;
    texture_desc.MipLevels = 1;
    texture_desc.Format = DXGI_FORMAT_R32G32B32A32_FLOAT;
    texture_desc.SampleDesc.Count = 1;
    texture_desc.Flags = D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET;
    ComPtr<ID3D12Resource> texture;
    check(device->CreateCommittedResource(&default_heap, D3D12_HEAP_FLAG_NONE, &texture_desc,
        D3D12_RESOURCE_STATE_RENDER_TARGET, nullptr, IID_PPV_ARGS(&texture)));
    D3D12_DESCRIPTOR_HEAP_DESC rtv_desc = {};
    rtv_desc.Type = D3D12_DESCRIPTOR_HEAP_TYPE_RTV;
    rtv_desc.NumDescriptors = 1;
    ComPtr<ID3D12DescriptorHeap> rtv_heap;
    check(device->CreateDescriptorHeap(&rtv_desc, IID_PPV_ARGS(&rtv_heap)));
    const auto rtv = rtv_heap->GetCPUDescriptorHandleForHeapStart();
    device->CreateRenderTargetView(texture.Get(), nullptr, rtv);

    D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprint;
    UINT rows;
    UINT64 row_size, total_size;
    device->GetCopyableFootprints(&texture_desc, 0, 1, 0, &footprint, &rows, &row_size, &total_size);
    const auto readback_heap = heap(D3D12_HEAP_TYPE_READBACK);
    const auto readback_desc = buffer_desc(total_size);
    ComPtr<ID3D12Resource> readback;
    check(device->CreateCommittedResource(&readback_heap, D3D12_HEAP_FLAG_NONE, &readback_desc,
        D3D12_RESOURCE_STATE_COPY_DEST, nullptr, IID_PPV_ARGS(&readback)));
    const float vertices[12] = {-1, -1, 0, 1, -1, 3, 0, 1, 3, -1, 0, 1};
    const auto upload_heap = heap(D3D12_HEAP_TYPE_UPLOAD);
    const auto upload_desc = buffer_desc(sizeof(vertices));
    ComPtr<ID3D12Resource> upload;
    check(device->CreateCommittedResource(&upload_heap, D3D12_HEAP_FLAG_NONE, &upload_desc,
        D3D12_RESOURCE_STATE_GENERIC_READ, nullptr, IID_PPV_ARGS(&upload)));
    void *mapped;
    D3D12_RANGE empty_range = {0, 0};
    check(upload->Map(0, &empty_range, &mapped));
    std::memcpy(mapped, vertices, sizeof(vertices));
    upload->Unmap(0, nullptr);

    D3D12_COMMAND_QUEUE_DESC queue_desc = {};
    ComPtr<ID3D12CommandQueue> queue;
    check(device->CreateCommandQueue(&queue_desc, IID_PPV_ARGS(&queue)));
    ComPtr<ID3D12CommandAllocator> allocator;
    check(device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, IID_PPV_ARGS(&allocator)));
    ComPtr<ID3D12GraphicsCommandList> commands;
    check(device->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, allocator.Get(), pipeline.Get(), IID_PPV_ARGS(&commands)));
    commands->SetGraphicsRootSignature(root.Get());
    D3D12_VIEWPORT viewport = {0, 0, 4, 4, 0, 1};
    D3D12_RECT scissor = {0, 0, 4, 4};
    commands->RSSetViewports(1, &viewport);
    commands->RSSetScissorRects(1, &scissor);
    commands->OMSetRenderTargets(1, &rtv, FALSE, nullptr);
    const float clear[4] = {-1, -1, -1, -1};
    commands->ClearRenderTargetView(rtv, clear, 0, nullptr);
    const D3D12_VERTEX_BUFFER_VIEW vertex_view = {upload->GetGPUVirtualAddress(), sizeof(vertices), 4 * sizeof(float)};
    commands->IASetVertexBuffers(0, 1, &vertex_view);
    commands->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    commands->DrawInstanced(3, 1, 0, 0);
    D3D12_RESOURCE_BARRIER barrier = {};
    barrier.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    barrier.Transition.pResource = texture.Get();
    barrier.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
    barrier.Transition.StateBefore = D3D12_RESOURCE_STATE_RENDER_TARGET;
    barrier.Transition.StateAfter = D3D12_RESOURCE_STATE_COPY_SOURCE;
    commands->ResourceBarrier(1, &barrier);
    D3D12_TEXTURE_COPY_LOCATION source = {};
    source.pResource = texture.Get();
    source.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
    D3D12_TEXTURE_COPY_LOCATION destination = {};
    destination.pResource = readback.Get();
    destination.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
    destination.PlacedFootprint = footprint;
    commands->CopyTextureRegion(&destination, 0, 0, 0, &source, nullptr);
    check(commands->Close());
    ID3D12CommandList *lists[] = {commands.Get()};
    queue->ExecuteCommandLists(1, lists);
    ComPtr<ID3D12Fence> fence;
    check(device->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(&fence)));
    check(queue->Signal(fence.Get(), 1));
    HANDLE event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    if (!event) throw std::runtime_error("CreateEvent failed");
    const HRESULT event_status = fence->SetEventOnCompletion(1, event);
    const DWORD wait = SUCCEEDED(event_status) ? WaitForSingleObject(event, 10000) : WAIT_FAILED;
    CloseHandle(event);
    check(event_status);
    if (wait != WAIT_OBJECT_0) throw std::runtime_error("GPU readback timed out");
    D3D12_RANGE read_range = {0, static_cast<SIZE_T>(total_size)};
    check(readback->Map(0, &read_range, &mapped));
    bool matches = true;
    for (UINT row = 0; row < 4; ++row) {
        const auto *pixels = reinterpret_cast<const float *>(static_cast<const char *>(mapped) + footprint.Offset + row * footprint.Footprint.RowPitch);
        for (UINT column = 0; column < 4; ++column)
            for (UINT channel = 0; channel < 4; ++channel)
                matches = matches && std::isfinite(pixels[column * 4 + channel]) && std::abs(pixels[column * 4 + channel] - expected[channel]) <= 0.000001f;
    }
    readback->Unmap(0, &empty_range);
    if (!matches) throw std::runtime_error("pixel readback differs from expected RGBA");
    if (messages) {
        for (UINT64 index = 0; index < messages->GetNumStoredMessagesAllowedByRetrievalFilter(); ++index) {
            SIZE_T size = 0;
            check(messages->GetMessage(index, nullptr, &size));
            std::vector<char> storage(size);
            auto *message = reinterpret_cast<D3D12_MESSAGE *>(storage.data());
            check(messages->GetMessage(index, message, &size));
            if (message->Severity <= D3D12_MESSAGE_SEVERITY_ERROR) {
                std::cerr << message->pDescription << "\n";
                throw std::runtime_error("D3D12 debug layer reported an error");
            }
        }
    }
    ensure_no_compiler();
    std::cout << "render passed: 16 pixels RGBA=" << expected[0] << "," << expected[1] << "," << expected[2] << "," << expected[3]
              << " pso_us=" << pso_us << " compiler_dlls=absent\n";
}

int main(int argc, char **argv) {
    try {
        if (argc != 4) throw std::runtime_error("usage: dxil-render <vertex> <fragment> <alternate-fragment>");
        ComPtr<ID3D12Debug> debug;
        const bool debug_enabled = SUCCEEDED(D3D12GetDebugInterface(IID_PPV_ARGS(&debug)));
        if (!debug_enabled) throw std::runtime_error("D3D12 debug layer required; install Windows Graphics Tools");
        if (debug_enabled) debug->EnableDebugLayer();
        std::cout << "debug_layer=" << (debug_enabled ? "enabled" : "unavailable") << "\n";
        ComPtr<IDXGIFactory1> factory;
        check(CreateDXGIFactory1(IID_PPV_ARGS(&factory)));
        const auto vertex = read(argv[1]);
        const auto fragment = read(argv[2]);
        const auto alternate = read(argv[3]);
        UINT tested = 0;
        for (UINT index = 0;; ++index) {
            ComPtr<IDXGIAdapter1> adapter;
            if (factory->EnumAdapters1(index, &adapter) == DXGI_ERROR_NOT_FOUND) break;
            DXGI_ADAPTER_DESC1 desc;
            check(adapter->GetDesc1(&desc));
            if (desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) continue;
            ComPtr<ID3D12Device> device;
            if (FAILED(D3D12CreateDevice(adapter.Get(), D3D_FEATURE_LEVEL_12_0, IID_PPV_ARGS(&device)))) continue;
            D3D12_FEATURE_DATA_SHADER_MODEL model = {D3D_SHADER_MODEL_6_5};
            if (FAILED(device->CheckFeatureSupport(D3D12_FEATURE_SHADER_MODEL, &model, sizeof(model))) || model.HighestShaderModel < D3D_SHADER_MODEL_6_5) continue;
            char name[256];
            WideCharToMultiByte(CP_UTF8, 0, desc.Description, -1, name, sizeof(name), nullptr, nullptr);
            std::cout << "adapter=" << name << " sm65=supported\n";
            render(device.Get(), vertex, fragment, {0.25f, 0.5f, 0.75f, 1});
            render(device.Get(), vertex, alternate, {0.75f, 0.25f, 0.5f, 1});
            ++tested;
        }
        if (!tested) throw std::runtime_error("no hardware adapter supports SM 6.5");
        std::cout << "hardware_adapters_passed=" << tested << "\n";
        return 0;
    } catch (const std::exception &error) {
        std::cerr << error.what() << "\n";
        return 1;
    }
}
