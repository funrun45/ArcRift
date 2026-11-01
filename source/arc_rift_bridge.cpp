// Experimental user-mode backend. No GPU driver patches or firmware writes.
// Reverse-engineered interface definitions: BnuuySolutions/OculusDirectDisplayAdditions (MIT).
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <dxgi1_2.h>
#include <d3d11.h>
#include <wrl/client.h>
#include <mutex>
#include <vector>
#include <cstdarg>
#include "ovr_direct_display.h"
#include "texture_summary.h"
#include "arcrift_identity.h"
using Microsoft::WRL::ComPtr;
static HMODULE self;
// Release 1.1: headset/GPU identity comes from arcrift-identity.txt next to this DLL.
static const ArcRiftIdentity& Identity() { static const ArcRiftIdentity id = ArcRiftLoadIdentity(self); return id; }

static void Trace(const char* format, ...) {
    wchar_t path[MAX_PATH]{};
    GetModuleFileNameW(self, path, MAX_PATH);
    wchar_t* last = wcsrchr(path, L'\\');
    if (!last) return;
    wcscpy_s(last + 1, MAX_PATH - (last + 1 - path), L"arc-rift-bridge.log");
    FILE* file = nullptr;
    if (_wfopen_s(&file, path, L"a") != 0) return;
    fprintf(file, "%llu ", GetTickCount64());
    va_list args;
    va_start(args, format);
    vfprintf(file, format, args);
    va_end(args);
    fputc('\n', file);
    fclose(file);
}

struct PhysicalOutput {
    LUID luid{};
    wchar_t sourceName[32]{};
    RECT rect{};
};

static bool GetPhysicalOutput(PhysicalOutput& out) {
    UINT count = 0, modes = 0;
    if (GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, &count, &modes)) return false;
    std::vector<DISPLAYCONFIG_PATH_INFO> paths(count);
    std::vector<DISPLAYCONFIG_MODE_INFO> modeData(modes);
    if (QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, &count, paths.data(), &modes, modeData.data(), nullptr)) return false;
    for (UINT i = 0; i < count; ++i) {
        if (!Identity().valid || paths[i].targetInfo.id != Identity().target) continue;
        DISPLAYCONFIG_TARGET_DEVICE_NAME target{};
        target.header = {DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME, sizeof(target), paths[i].targetInfo.adapterId, paths[i].targetInfo.id};
        if (DisplayConfigGetDeviceInfo(&target.header)) continue;
        // Release 1.1: exact headset device path from the identity file (stricter than the old prefix check).
        if (!Identity().MonitorMatches(target.monitorDevicePath)) continue;
        DISPLAYCONFIG_SOURCE_DEVICE_NAME source{};
        source.header = {DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME, sizeof(source), paths[i].sourceInfo.adapterId, paths[i].sourceInfo.id};
        if (DisplayConfigGetDeviceInfo(&source.header)) continue;
        DEVMODEW mode{};
        mode.dmSize = sizeof(mode);
        if (!EnumDisplaySettingsW(source.viewGdiDeviceName, ENUM_CURRENT_SETTINGS, &mode)) continue;
        out.luid = paths[i].targetInfo.adapterId;
        wcscpy_s(out.sourceName, source.viewGdiDeviceName);
        out.rect = {mode.dmPosition.x, mode.dmPosition.y, mode.dmPosition.x + LONG(mode.dmPelsWidth), mode.dmPosition.y + LONG(mode.dmPelsHeight)};
        return true;
    }
    return false;
}




static bool ReadTestEdid(char* output) {
    wchar_t path[MAX_PATH]{};
    GetModuleFileNameW(self, path, MAX_PATH);
    wchar_t* last = wcsrchr(path, L'\\');
    if (!last) return false;
    wcscpy_s(last + 1, MAX_PATH - (last + 1 - path), L"rift-s-native-test.edid");
    FILE* file = nullptr;
    if (_wfopen_s(&file, path, L"rb") != 0) return false;
    memset(output, 0, 256);
    size_t count = fread(output, 1, 128, file);
    fclose(file);
    unsigned sum = 0;
    for (size_t i = 0; i < 128; ++i) sum += static_cast<unsigned char>(output[i]);
    return count == 128 && sum % 256 == 0 && static_cast<unsigned char>(output[8]) == 0x3e && static_cast<unsigned char>(output[9]) == 0xd2;
}

class Surface final : public OVR::IDirectDisplaySurface {
    OVR_REF_COUNTED_IMPLEMENTATION
public:
    ComPtr<ID3D11Texture2D> texture;
    ComPtr<ID3D11Texture2D> consumerTexture; // Used only by isolated candidate build.
    HANDLE shared = nullptr;
    bool handleLogged = false;
    void* QueryInterface(uint64_t id) override {
        Trace("Surface %p QueryInterface %llx", this, id);
        if (id == OVR::IID_IDirectDisplaySurface || id == 1 || id == 2) return static_cast<OVR::IDirectDisplaySurface*>(this);
        return nullptr;
    }
    HANDLE GetSurfaceHandle() override {
        if (!handleLogged) { Trace("Surface %p GetSurfaceHandle=%p", this, shared); handleLogged = true; }
        return shared;
    }
};

class Display final : public OVR::IDirectDisplay {
    OVR_REF_COUNTED_IMPLEMENTATION
    std::mutex mutex;
    ComPtr<ID3D11Device> device;
    ComPtr<ID3D11DeviceContext> context;
    ComPtr<IDXGISwapChain1> chain;
    HWND window = nullptr;
    UINT width = 0, height = 0;
    unsigned frames = 0;
    std::vector<Surface*> ownedSurfaces;
    bool unknownPresentLogged = false;

    void SampleOutput(ID3D11Texture2D* source) {
        TextureSummary s;
        HRESULT hr = SummarizeTexture(device.Get(), context.Get(), source, s);
        Trace("Output surface frame=%u readback=%08lx size=%ux%u pixels=%llu nonblack=%llu green=%llu maxRGBA=%u,%u,%u,%u",
            frames, hr, s.width, s.height, s.pixels, s.nonblack, s.greenDominant,
            s.maxRGB[0], s.maxRGB[1], s.maxRGB[2], s.maxAlpha);
    }

    static LRESULT CALLBACK Proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
        return DefWindowProcW(hwnd, msg, wp, lp);
    }

    HRESULT InitializeRenderer(UINT w, UINT h) {
        if (chain) return width == w && height == h ? S_OK : E_INVALIDARG;
        PhysicalOutput output;
        if (!GetPhysicalOutput(output)) return DXGI_ERROR_NOT_FOUND;
        ComPtr<IDXGIFactory1> factory;
        HRESULT hr = CreateDXGIFactory1(IID_PPV_ARGS(&factory));
        if (FAILED(hr)) return hr;
        ComPtr<IDXGIAdapter1> adapter;
        for (UINT i = 0;; ++i) {
            ComPtr<IDXGIAdapter1> candidate;
            if (factory->EnumAdapters1(i, &candidate) == DXGI_ERROR_NOT_FOUND) break;
            if (!candidate) break;
            DXGI_ADAPTER_DESC1 desc{};
            candidate->GetDesc1(&desc);
            if (memcmp(&desc.AdapterLuid, &output.luid, sizeof(LUID)) == 0 && Identity().GpuAllowed(desc.VendorId, desc.DeviceId)) { adapter = candidate; break; }
        }
        if (!adapter) return DXGI_ERROR_NOT_FOUND;
        if (!device) {
            hr = D3D11CreateDevice(adapter.Get(), D3D_DRIVER_TYPE_UNKNOWN, nullptr, 0, nullptr, 0, D3D11_SDK_VERSION, &device, nullptr, &context);
            if (FAILED(hr)) return hr;
        } else {
            ComPtr<IDXGIDevice> dxgiDevice;
            ComPtr<IDXGIAdapter> actualAdapter;
            DXGI_ADAPTER_DESC actualDesc{};
            hr = device.As(&dxgiDevice);
            if (SUCCEEDED(hr)) hr = dxgiDevice->GetAdapter(&actualAdapter);
            if (SUCCEEDED(hr)) hr = actualAdapter->GetDesc(&actualDesc);
            if (FAILED(hr) || memcmp(&actualDesc.AdapterLuid, &output.luid, sizeof(LUID)) != 0) return DXGI_ERROR_INVALID_CALL;
        }
        WNDCLASSW wc{};
        wc.hInstance = self;
        wc.lpszClassName = L"ArcRiftExperimentalBridge";
        wc.lpfnWndProc = Proc;
        RegisterClassW(&wc);
        window = CreateWindowExW(WS_EX_TOPMOST | WS_EX_NOACTIVATE, wc.lpszClassName, L"Experimental Rift S display backend",
            WS_POPUP, output.rect.left, output.rect.top, output.rect.right - output.rect.left,
            output.rect.bottom - output.rect.top, nullptr, nullptr, self, nullptr);
        if (!window) return HRESULT_FROM_WIN32(GetLastError());
        ComPtr<IDXGIFactory2> factory2;
        hr = factory.As(&factory2);
        if (FAILED(hr)) return hr;
        DXGI_SWAP_CHAIN_DESC1 desc{};
        desc.Width = w;
        desc.Height = h;
        desc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
        desc.SampleDesc.Count = 1;
        desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
        desc.BufferCount = 2;
        desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL;
        desc.Scaling = DXGI_SCALING_STRETCH;
        desc.AlphaMode = DXGI_ALPHA_MODE_IGNORE;
        hr = factory2->CreateSwapChainForHwnd(device.Get(), window, &desc, nullptr, nullptr, &chain);
        if (FAILED(hr)) return hr;
        factory->MakeWindowAssociation(window, DXGI_MWA_NO_ALT_ENTER);
        width = w;
        height = h;
        ShowWindow(window, SW_SHOWNOACTIVATE);
        DWORD sessionId = 0;
        ProcessIdToSessionId(GetCurrentProcessId(), &sessionId);
        wchar_t desktop[128]{};
        DWORD needed = 0;
        GetUserObjectInformationW(GetThreadDesktop(GetCurrentThreadId()), UOI_NAME, desktop, sizeof(desktop), &needed);
        ComPtr<IDXGIOutput> containing;
        DXGI_OUTPUT_DESC actual{};
        hr = chain->GetContainingOutput(&containing);
        if (SUCCEEDED(hr)) containing->GetDesc(&actual);
        Trace("Window session=%lu desktop=%ls visible=%d intended=%ls containing=%ls rect=%ld,%ld,%ld,%ld outputHR=%08lx",
            sessionId, desktop, IsWindowVisible(window), output.sourceName, actual.DeviceName,
            output.rect.left, output.rect.top, output.rect.right, output.rect.bottom, hr);
        Trace("Renderer initialized %ux%u, verified physical target %u", w, h, Identity().target);
        return S_OK;
    }
public:
    ~Display() override {
        for (auto surface : ownedSurfaces) surface->Release();
        if (window) DestroyWindow(window);
    }
    void* QueryInterface(uint64_t id) override {
        Trace("Display QueryInterface %llx", id);
        if (id == OVR::IID_IDirectDisplay || id == 1 || id == 2) return static_cast<OVR::IDirectDisplay*>(this);
        return nullptr;
    }
    ovrResult GetProperties(ovrDisplayProperties* props) override {
        Trace("GetProperties");
        if (!props) return ovrError_InvalidParameter;
        memset(props, 0, sizeof(*props));
        // The output is physically verified; never substitute another monitor.
        PhysicalOutput output;
        if (!GetPhysicalOutput(output)) return ovrError_Unsupported;
        memcpy(props->Luid.Reserved, &output.luid, sizeof(output.luid));
        props->OutputType = ovrDisplayOutput_DP;
        props->DongleType = ovrDisplayDongle_None;
        props->UniqueId = Identity().target;
        return ReadTestEdid(props->EdidData) ? ovrSuccess : ovrError_Unsupported;
    }
    ovrResult AcquireExclusive(::IUnknown* supplied) override {
        std::lock_guard<std::mutex> guard(mutex);
        if (!supplied) return ovrError_InvalidParameter;
        ComPtr<ID3D11Device> suppliedDevice;
        HRESULT hr = supplied->QueryInterface(IID_PPV_ARGS(&suppliedDevice));
        Trace("AcquireExclusive supplied D3D11 device QI=%08lx: composited, not hardware direct mode", hr);
        if (FAILED(hr)) return ovrError_Unsupported;
        if (chain && suppliedDevice.Get() != device.Get()) {
            Trace("AcquireExclusive device changed while renderer active; refusing stale device reuse");
            return ovrError_Unsupported;
        }
        device = suppliedDevice;
        device->GetImmediateContext(&context);
        return ovrSuccess;
    }
    ovrResult ReleaseExclusive() override { Trace("ReleaseExclusive"); return ovrSuccess; }
    ovrResult CreateSurface(ovrModeDesc* mode, OVR::IDirectDisplaySurface** out) override {
        if (!mode || !out) return ovrError_InvalidParameter;
        *out = nullptr;
        Trace("CreateSurface %dx%d rate=%d/%d format=%d", mode->Resolution.w, mode->Resolution.h,
            mode->RefreshRate.Numerator, mode->RefreshRate.Denominator, mode->Format);
        if (mode->Resolution.w != 1440 || mode->Resolution.h != 2560 || mode->RefreshRate.Denominator <= 0 ||
            mode->RefreshRate.Numerator < 79 * mode->RefreshRate.Denominator || mode->RefreshRate.Numerator > 81 * mode->RefreshRate.Denominator ||
            (mode->Format != OVR_FORMAT_R8G8B8A8_UNORM && mode->Format != OVR_FORMAT_R8G8B8A8_UNORM_SRGB)) return ovrError_Unsupported;
        std::lock_guard<std::mutex> guard(mutex);
        HRESULT hr = InitializeRenderer(1440, 2560);
        if (FAILED(hr)) { Trace("Renderer failed %08lx", hr); return ovrError_Unsupported; }
        auto surface = new Surface;
        D3D11_TEXTURE2D_DESC desc{};
        desc.Width = width;
        desc.Height = height;
        desc.MipLevels = desc.ArraySize = 1;
        desc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
        desc.SampleDesc.Count = 1;
        desc.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_UNORDERED_ACCESS | D3D11_BIND_SHADER_RESOURCE;
        desc.MiscFlags = D3D11_RESOURCE_MISC_SHARED;
        hr = device->CreateTexture2D(&desc, nullptr, &surface->texture);
        ComPtr<IDXGIResource> resource;
        if (SUCCEEDED(hr)) hr = surface->texture.As(&resource);
        if (SUCCEEDED(hr)) hr = resource->GetSharedHandle(&surface->shared);
        if (FAILED(hr)) { Trace("Surface failed %08lx", hr); surface->Release(); return ovrError_Unsupported; }
        *out = surface;
        surface->AddRef();
        ownedSurfaces.push_back(surface);
        Trace("Created surface=%p shared=%p", surface, surface->shared);
        return ovrSuccess;
    }
    ovrResult Present(void* value, void* auxiliary) override {
        if (!value) return ovrError_InvalidParameter;
        std::lock_guard<std::mutex> guard(mutex);
        if (!chain) return ovrError_Unsupported;
        Surface* surface = nullptr;
        for (auto known : ownedSurfaces) if (value == known) { surface = known; break; }
        if (!surface) {
            void* firstPointer = nullptr;
            SIZE_T obtained = 0;
            BOOL read = ReadProcessMemory(GetCurrentProcess(), value, &firstPointer, sizeof(firstPointer), &obtained);
            if (read && obtained == sizeof(firstPointer)) {
                for (auto known : ownedSurfaces) if (firstPointer == known) { surface = known; break; }
            }
            if (frames == 0 || (!surface && !unknownPresentLogged))
                Trace("Present descriptor=%p firstPointer=%p verifiedSurface=%p auxiliary=%p", value, firstPointer, surface, auxiliary);
            if (!surface) { unknownPresentLogged = true; return ovrError_Unsupported; }
        }
        if (frames == 0) Trace("First presented verified surface=%p shared=%p", surface, surface->shared);
        ComPtr<ID3D11Texture2D> back;
        HRESULT hr = chain->GetBuffer(0, IID_PPV_ARGS(&back));
        if (FAILED(hr)) return ovrError_Unsupported;
        context->CopyResource(back.Get(), surface->texture.Get());
        if (frames == 30 || (frames != 0 && frames % 120 == 0)) SampleOutput(back.Get());
        hr = chain->Present(1, 0);
        if (frames++ == 0 || FAILED(hr)) Trace("Present frame=%u result=%08lx", frames, hr);
        MSG message{};
        while (PeekMessageW(&message, window, 0, 0, PM_REMOVE)) { TranslateMessage(&message); DispatchMessageW(&message); }
        return SUCCEEDED(hr) ? ovrSuccess : ovrError_Unsupported;
    }
    ovrResult GetPresentStateTimeout(int) override { return ovrSuccess; }
    ovrResult GetPresentStats(ovrPresentStats* stats) override {
        if (!stats) return ovrError_InvalidParameter;
        memset(stats, 0, sizeof(*stats));
        stats->RefreshRate = {80, 1};
        return ovrSuccess;
    }
    ovrResult GetPresentState(ovrBool* state) override { if (!state) return ovrError_InvalidParameter; *state = ovrFalse; return ovrSuccess; }
    ovrResult GetHdcpState(ovrBool* state) override {
        // Do not falsely claim encryption on this composited display path.
        if (!state) return ovrError_InvalidParameter;
        *state = ovrFalse;
        return ovrSuccess;
    }
};


class Provider final : public OVR::IDirectDisplayAPI {
    OVR_REF_COUNTED_IMPLEMENTATION
    Display* display = new Display;
public:
    ~Provider() override { display->Release(); }
    void* QueryInterface(uint64_t id) override {
        if (id == OVR::IID_IDirectDisplayAPI || id == 1 || id == 2) return static_cast<OVR::IDirectDisplayAPI*>(this);
        return nullptr;
    }
    ovrResult EnableDirectDisplay(ovrBool enable) override { Trace("EnableDirectDisplay %d: no OS mode changes", enable); return ovrSuccess; }
    ovrResult Enumerate(uint32_t index, OVR::IDirectDisplay** out) override {
        if (!out) return ovrError_InvalidParameter;
        *out = nullptr;
        if (index != 0) return ovrError_Unsupported;
        if (!Identity().valid) { Trace("Identity file arcrift-identity.txt missing or invalid; refusing to enumerate"); return ovrError_Unsupported; }
        PhysicalOutput output;
        if (!GetPhysicalOutput(output)) return ovrError_Unsupported;
        display->AddRef();
        *out = display;
        Trace("Enumerate verified target %u", Identity().target);
        return ovrSuccess;
    }
    ovrResult GetName(char* name) override {
        if (!name) return ovrError_InvalidParameter;
        strcpy_s(name, 128, "ArcRiftLab (experimental composited)");
        return ovrSuccess;
    }
};

OVR_EXPORT ovrResult DirectDisplayInitialize(uint64_t id, OVR::IDirectDisplayAPI** out) {
    Trace("DirectDisplayInitialize requested IID=%llx", id);
    if (!out) return ovrError_InvalidParameter;
    *out = nullptr;
    if (id != OVR::IID_IDirectDisplayAPI) return ovrError_Unsupported;
    *out = new Provider;
    return ovrSuccess;
}

BOOL WINAPI DllMain(HINSTANCE module, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) { self = module; DisableThreadLibraryCalls(module); }
    return TRUE;
}
