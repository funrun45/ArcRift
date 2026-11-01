#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <dxgi1_2.h>
#include <d3d11.h>
#include <cstdio>
#include <vector>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Devices.Display.h>
#include <winrt/Windows.Devices.Display.Core.h>

int main() {
    puts("Arc/Rift read-only display probe. No display settings are changed.");
    IDXGIFactory1* factory = nullptr;
    HRESULT hr = CreateDXGIFactory1(IID_PPV_ARGS(&factory));
    printf("CreateDXGIFactory1: %08lx\n", hr);
    if (SUCCEEDED(hr)) {
        for (UINT i = 0;; ++i) {
            IDXGIAdapter1* adapter = nullptr;
            if (factory->EnumAdapters1(i, &adapter) == DXGI_ERROR_NOT_FOUND) break;
            if (!adapter) break;
            DXGI_ADAPTER_DESC1 desc{};
            adapter->GetDesc1(&desc);
            printf("GPU %u: %ls vendor=%04x device=%04x LUID=%08lx:%08lx\n", i,
                desc.Description, desc.VendorId, desc.DeviceId,
                desc.AdapterLuid.HighPart, desc.AdapterLuid.LowPart);
            ID3D11Device* device = nullptr;
            D3D_FEATURE_LEVEL level{};
            hr = D3D11CreateDevice(adapter, D3D_DRIVER_TYPE_UNKNOWN, nullptr, 0,
                nullptr, 0, D3D11_SDK_VERSION, &device, &level, nullptr);
            printf("  D3D11CreateDevice=%08lx feature=%x\n", hr, level);
            if (device) device->Release();
            for (UINT j = 0;; ++j) {
                IDXGIOutput* output = nullptr;
                if (adapter->EnumOutputs(j, &output) == DXGI_ERROR_NOT_FOUND) break;
                if (!output) break;
                DXGI_OUTPUT_DESC out{};
                output->GetDesc(&out);
                printf("  Output %u: %ls desktop=%d monitor=%p rect=%ld,%ld,%ld,%ld\n",
                    j, out.DeviceName, out.AttachedToDesktop, out.Monitor,
                    out.DesktopCoordinates.left, out.DesktopCoordinates.top,
                    out.DesktopCoordinates.right, out.DesktopCoordinates.bottom);
                output->Release();
            }
            adapter->Release();
        }
        factory->Release();
    }
    for (UINT flags : {UINT(QDC_ALL_PATHS), UINT(QDC_ONLY_ACTIVE_PATHS | QDC_INCLUDE_HMD)}) {
        UINT paths = 0, modes = 0;
        LONG status = GetDisplayConfigBufferSizes(flags, &paths, &modes);
        printf("DisplayConfig flags=%x sizes=%ld paths=%u modes=%u\n", flags, status, paths, modes);
        if (status != ERROR_SUCCESS) continue;
        std::vector<DISPLAYCONFIG_PATH_INFO> p(paths);
        std::vector<DISPLAYCONFIG_MODE_INFO> m(modes);
        status = QueryDisplayConfig(flags, &paths, p.data(), &modes, m.data(), nullptr);
        printf("  QueryDisplayConfig=%ld\n", status);
        if (status != ERROR_SUCCESS) continue;
        for (UINT i = 0; i < paths; ++i) {
            const auto& target = p[i].targetInfo;
            // Disconnected paths have no monitor identity; skip their boilerplate.
            if (!target.targetAvailable && !(target.statusFlags & DISPLAYCONFIG_TARGET_IS_HMD)) continue;
            DISPLAYCONFIG_TARGET_DEVICE_NAME name{};
            name.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME;
            name.header.size = sizeof(name);
            name.header.adapterId = target.adapterId;
            name.header.id = target.id;
            LONG result = DisplayConfigGetDeviceInfo(&name.header);
            printf("  target=%u available=%d pathFlags=%x status=%x HMD=%d tech=%d nameResult=%ld\n",
                target.id, target.targetAvailable, p[i].flags, target.statusFlags,
                !!(target.statusFlags & DISPLAYCONFIG_TARGET_IS_HMD), target.outputTechnology, result);
            if (result == ERROR_SUCCESS) printf("    name=%ls path=%ls EDID=%04x:%04x\n",
                name.monitorFriendlyDeviceName, name.monitorDevicePath,
                name.edidManufactureId, name.edidProductCodeId);
            if ((p[i].flags & DISPLAYCONFIG_PATH_ACTIVE) && target.modeInfoIdx < modes && m[target.modeInfoIdx].infoType == DISPLAYCONFIG_MODE_INFO_TYPE_TARGET) {
                auto const& signal = m[target.modeInfoIdx].targetMode.targetVideoSignalInfo;
                printf("    signal=%ux%u total=%ux%u pixelClock=%llu vSync=%u/%u rotation=%u\n",
                    signal.activeSize.cx, signal.activeSize.cy, signal.totalSize.cx, signal.totalSize.cy,
                    signal.pixelRate, signal.vSyncFreq.Numerator, signal.vSyncFreq.Denominator, target.rotation);
                const auto& source = p[i].sourceInfo;
                if (source.modeInfoIdx < modes && m[source.modeInfoIdx].infoType == DISPLAYCONFIG_MODE_INFO_TYPE_SOURCE) {
                    const auto& s = m[source.modeInfoIdx].sourceMode;
                    printf("    source=%ux%u pixelFormat=%u scaling=%u\n", s.width, s.height, s.pixelFormat, target.scaling);
                }
                DISPLAYCONFIG_GET_ADVANCED_COLOR_INFO color{};
                color.header = {DISPLAYCONFIG_DEVICE_INFO_GET_ADVANCED_COLOR_INFO, sizeof(color), target.adapterId, target.id};
                LONG cr = DisplayConfigGetDeviceInfo(&color.header);
                printf("    colorInfoResult=%ld encoding=%u bitsPerChannel=%u advancedColorEnabled=%u\n",
                    cr, color.colorEncoding, color.bitsPerColorChannel, color.advancedColorEnabled);
            }
        }
    }
    try {
        winrt::init_apartment(winrt::apartment_type::multi_threaded);
        using namespace winrt::Windows::Devices::Display;
        using namespace winrt::Windows::Devices::Display::Core;
        auto manager = DisplayManager::Create(DisplayManagerOptions::None);
        auto targets = manager.GetCurrentTargets();
        printf("DisplayManager targets=%u\n", targets.Size());
        for (auto const& target : targets) {
            printf("  target=%u connected=%d usage=%d path=%ls\n",
                target.AdapterRelativeId(), target.IsConnected(), int(target.UsageKind()),
                target.DeviceInterfacePath().c_str());
            auto monitor = target.TryGetMonitor();
            if (monitor) {
                auto res = monitor.NativeResolutionInRawPixels();
                printf("    monitor=%ls native=%dx%d\n", monitor.DisplayName().c_str(), res.Width, res.Height);
                auto edid = monitor.GetDescriptor(DisplayMonitorDescriptorKind::Edid);
                printf("    EDID=");
                for (auto b : edid) printf("%02x", b);
                puts("");
            }
        }
        manager.Close();
    } catch (winrt::hresult_error const& error) {
        printf("DisplayManager error=%08x %ls\n", unsigned(error.code().value), error.message().c_str());
    }
    return 0;
}
