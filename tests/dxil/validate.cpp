#include <windows.h>
#include <dxcapi.h>
#include <wrl/client.h>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <iostream>
#include <iterator>
#include <stdexcept>
#include <vector>

using Microsoft::WRL::ComPtr;

void ComputeHashRetail(const BYTE *data, UINT byte_count, BYTE *digest);

static void check(HRESULT status) {
    if (FAILED(status)) throw std::runtime_error("COM operation failed");
}

static std::vector<char> read(const char *path) {
    std::ifstream file(path, std::ios::binary);
    if (!file) throw std::runtime_error("cannot read shader");
    return {std::istreambuf_iterator<char>(file), std::istreambuf_iterator<char>()};
}

static bool validate(IDxcLibrary *library, IDxcValidator *validator,
                     const std::vector<char> &bytes, bool expect_success) {
    ComPtr<IDxcBlobEncoding> blob;
    check(library->CreateBlobWithEncodingOnHeapCopy(bytes.data(), static_cast<UINT32>(bytes.size()), 0, &blob));
    ComPtr<IDxcOperationResult> operation;
    check(validator->Validate(blob.Get(), DxcValidatorFlags_Default, &operation));
    HRESULT status;
    check(operation->GetStatus(&status));
    if (expect_success && FAILED(status)) {
        ComPtr<IDxcBlobEncoding> errors;
        check(operation->GetErrorBuffer(&errors));
        std::cerr.write(static_cast<const char *>(errors->GetBufferPointer()), errors->GetBufferSize());
        return false;
    }
    if (expect_success) {
        ComPtr<IDxcBlob> signed_blob;
        check(operation->GetResult(&signed_blob));
        if (signed_blob->GetBufferSize() != bytes.size() ||
            std::memcmp(signed_blob->GetBufferPointer(), bytes.data(), bytes.size()) != 0) {
            std::cerr << "official validation changed the emitted container or retail hash\n";
            return false;
        }
    }
    return expect_success == SUCCEEDED(status);
}

int main(int argc, char **argv) {
    try {
        if (argc < 4) throw std::runtime_error("usage: dxil-validate <dxcompiler.dll> <hash-vectors> <shader>...");
        const auto vectors = read(argv[2]);
        if (vectors.empty() || vectors.size() % 20) throw std::runtime_error("invalid hash vector file");
        for (std::size_t offset = 0; offset < vectors.size(); offset += 20) {
            std::uint32_t length;
            std::memcpy(&length, vectors.data() + offset, 4);
            if (length > 4096) throw std::runtime_error("hash vector too large");
            std::vector<BYTE> input(length + 64);
            for (std::uint32_t index = 0; index < length; ++index) input[index] = static_cast<BYTE>(index * 17 + length);
            BYTE digest[16];
            ComputeHashRetail(input.data(), length, digest);
            if (std::memcmp(digest, vectors.data() + offset + 4, 16)) throw std::runtime_error("retail hash differs from pinned DXC reference");
        }
        std::cout << "retail hash reference vectors passed=" << vectors.size() / 20 << "\n";
        HMODULE module = LoadLibraryExA(argv[1], nullptr, LOAD_WITH_ALTERED_SEARCH_PATH);
        if (!module) throw std::runtime_error("cannot load official DXC library");
        const auto create = reinterpret_cast<DxcCreateInstanceProc>(GetProcAddress(module, "DxcCreateInstance"));
        if (!create) throw std::runtime_error("DxcCreateInstance missing");
        ComPtr<IDxcLibrary> library;
        ComPtr<IDxcValidator> validator;
        check(create(CLSID_DxcLibrary, IID_PPV_ARGS(&library)));
        check(create(CLSID_DxcValidator, IID_PPV_ARGS(&validator)));
        ComPtr<IDxcVersionInfo> version;
        check(validator.As(&version));
        UINT32 major, minor;
        check(version->GetVersion(&major, &minor));
        std::cout << "official validator " << major << "." << minor << "\n";
        for (int index = 3; index < argc; ++index) {
            auto bytes = read(argv[index]);
            if (!validate(library.Get(), validator.Get(), bytes, true)) return 1;
            std::cout << "validated unchanged: " << argv[index] << "\n";
            std::uint32_t count;
            std::memcpy(&count, bytes.data() + 28, 4);
            bool mutated = false;
            for (std::uint32_t part = 0; part < count; ++part) {
                std::uint32_t offset;
                std::memcpy(&offset, bytes.data() + 32 + part * 4, 4);
                if (std::memcmp(bytes.data() + offset, "OSG1", 4) == 0) {
                    bytes[offset + 8 + 8 + 16] = 2;
                    mutated = true;
                    break;
                }
            }
            if (mutated) {
                BYTE digest[16];
                ComputeHashRetail(reinterpret_cast<const BYTE *>(bytes.data() + 20), static_cast<UINT>(bytes.size() - 20), digest);
                std::memcpy(bytes.data() + 4, digest, sizeof(digest));
            }
            if (!mutated || !validate(library.Get(), validator.Get(), bytes, false)) {
                std::cerr << "validator failed to reject inconsistent signature\n";
                return 1;
            }
            std::cout << "rejected inconsistent output signature\n";
        }
        return 0;
    } catch (const std::exception &error) {
        std::cerr << error.what() << "\n";
        return 1;
    }
}
