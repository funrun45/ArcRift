#include "ovr_direct_display.h"
#include "arcrift_identity.h"
#include <cstring>
int main(int argc, char** argv) {
    bool isolated = argc == 2 && strcmp(argv[1], "--isolated") == 0;
    bool noReadback = argc == 2 && strcmp(argv[1], "--no-readback") == 0;
    bool startup = argc == 2 && strcmp(argv[1], "--startup") == 0;
    if (argc > 1 && !isolated && !noReadback && !startup) return 2;
    static_assert(sizeof(ovrDisplayProperties) == 280, "Unexpected interface layout");
    static_assert(sizeof(ovrModeDesc) == 24, "Unexpected mode layout");
    auto module = LoadLibraryW(startup ? L".\\arc_rift_bridge_startup.dll" : (isolated ? L".\\arc_rift_bridge_isolated.dll" : (noReadback ? L".\\arc_rift_bridge_noreadback.dll" : L".\\arc_rift_bridge.dll")));
    if (!module) { printf("Load failed %lu\n", GetLastError()); return 1; }
    using Init = ovrResult (*)(uint64_t, OVR::IDirectDisplayAPI**);
    auto init = reinterpret_cast<Init>(GetProcAddress(module, "DirectDisplayInitialize"));
    if (!init) return 1;
    OVR::IDirectDisplayAPI* provider = nullptr;
    auto result = init(OVR::IID_IDirectDisplayAPI, &provider);
    printf("Initialize=%d\n", result);
    if (result || !provider) return 1;
    char name[128]{};
    result = provider->GetName(name);
    bool failed = result != ovrSuccess;
    printf("GetName=%d %s\n", result, name);
    OVR::IDirectDisplay* display = nullptr;
    result = provider->Enumerate(0, &display);
    if (result != ovrSuccess || !display) failed = true;
    printf("Enumerate=%d\n", result);
    if (result == ovrSuccess && display) {
        ovrDisplayProperties props{};
        result = display->GetProperties(&props);
        if (result != ovrSuccess || props.UniqueId != ArcRiftLoadIdentity(nullptr).target) failed = true;
        printf("GetProperties=%d output=%d id=%llu EDID=%02x%02x:%02x%02x\n", result,
            props.OutputType, props.UniqueId,
            static_cast<unsigned char>(props.EdidData[8]), static_cast<unsigned char>(props.EdidData[9]),
            static_cast<unsigned char>(props.EdidData[11]), static_cast<unsigned char>(props.EdidData[10]));
        display->Release();
    }
    display = nullptr;
    result = provider->Enumerate(1, &display);
    if (result != ovrError_Unsupported || display) failed = true;
    printf("End of enumeration=%d null=%d\n", result, display == nullptr);
    provider->Release();
    FreeLibrary(module);
    return failed ? 1 : 0;
}
