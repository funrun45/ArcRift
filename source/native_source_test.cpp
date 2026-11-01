// Resize only the verified headset's desktop surface, not its physical timing.
// --hold: temporary apply with a 45-second best-effort source restore.
// --hold-managed: harness MUST remove EDID/restart original runtime and verify rollback.
// --restore: emergency narrow restoration from the local backup.
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <vector>
#include "arcrift_identity.h"

struct SavedSource {
    DWORD magic = 0x41525331;
    LUID adapter{};
    UINT sourceId = 0;
    DISPLAYCONFIG_SOURCE_MODE source{};
    DISPLAYCONFIG_SCALING scaling{};
};
struct Configuration {
    std::vector<DISPLAYCONFIG_PATH_INFO> paths;
    std::vector<DISPLAYCONFIG_MODE_INFO> modes;
    UINT chosen = UINT_MAX;
    bool Read() {
        UINT np = 0, nm = 0;
        LONG r = GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, &np, &nm);
        if (r) return false;
        paths.resize(np); modes.resize(nm);
        r = QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, &np, paths.data(), &nm, modes.data(), nullptr);
        if (r) return false;
        paths.resize(np); modes.resize(nm);
        for (UINT i = 0; i < np; ++i) {
            auto& p = paths[i];
            static const ArcRiftIdentity identity = ArcRiftLoadIdentity(nullptr);
            if (!identity.valid || p.targetInfo.id != identity.target) continue;
            DISPLAYCONFIG_TARGET_DEVICE_NAME name{};
            name.header = {DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME, sizeof(name), p.targetInfo.adapterId, p.targetInfo.id};
            if (DisplayConfigGetDeviceInfo(&name.header) || !identity.MonitorMatches(name.monitorDevicePath)) continue;
            if (p.sourceInfo.modeInfoIdx >= nm || p.targetInfo.modeInfoIdx >= nm) return false;
            if (modes[p.sourceInfo.modeInfoIdx].infoType != DISPLAYCONFIG_MODE_INFO_TYPE_SOURCE || modes[p.targetInfo.modeInfoIdx].infoType != DISPLAYCONFIG_MODE_INFO_TYPE_TARGET) return false;
            // Refuse cloned sources: this must not resize another monitor.
            for (UINT j = 0; j < np; ++j) if (i != j && paths[j].sourceInfo.id == p.sourceInfo.id &&
                memcmp(&paths[j].sourceInfo.adapterId, &p.sourceInfo.adapterId, sizeof(LUID)) == 0) return false;
            chosen = i;
            return true;
        }
        return false;
    }
    LONG Submit(UINT flag) {
        // No ALLOW_CHANGES or SAVE_TO_DATABASE: exact supplied layout, temporary.
        return SetDisplayConfig(static_cast<UINT>(paths.size()), paths.data(), static_cast<UINT>(modes.size()), modes.data(), SDC_USE_SUPPLIED_DISPLAY_CONFIG | flag);
    }
};

static bool Restore(const SavedSource& saved) {
    Configuration c;
    if (!c.Read()) { puts("RESTORE ERROR: Verified output unavailable."); return false; }
    auto& p = c.paths[c.chosen];
    if (saved.magic != 0x41525331 || saved.sourceId != p.sourceInfo.id || memcmp(&saved.adapter, &p.sourceInfo.adapterId, sizeof(LUID))) return false;
    c.modes[p.sourceInfo.modeInfoIdx].sourceMode = saved.source;
    p.targetInfo.scaling = saved.scaling;
    LONG r = c.Submit(SDC_VALIDATE);
    printf("Restore validate=%ld\n", r);
    if (r) return false;
    r = c.Submit(SDC_APPLY);
    printf("Restore apply=%ld\n", r);
    return r == ERROR_SUCCESS;
}

int main(int argc, char** argv) {
    setvbuf(stdout, nullptr, _IONBF, 0);
#ifdef ARC_RIFT_MANUAL_SESSION
    struct OwnerHandle { HANDLE value = nullptr; ~OwnerHandle() { if (value) CloseHandle(value); } } owner;
    if (argc == 2 && strcmp(argv[1], "--session-policy-selftest") == 0) {
        HANDLE event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
        if (!event) return 1;
        bool alive = WaitForSingleObject(event, 0) == WAIT_TIMEOUT;
        SetEvent(event);
        bool exited = WaitForSingleObject(event, 0) == WAIT_OBJECT_0;
        CloseHandle(event);
        puts(alive && exited ? "PASS: owner-alive/owner-exit policy; no display access" : "FAIL: owner policy");
        return alive && exited ? 0 : 1;
    }
    bool session = argc == 3 && strcmp(argv[1], "--hold-session") == 0;
    if (session) {
        char* end = nullptr;
        unsigned long pid = strtoul(argv[2], &end, 10);
        DWORD theirs = 0, ours = 0;
        if (!*argv[2] || *end || !pid || !ProcessIdToSessionId(pid, &theirs) ||
            !ProcessIdToSessionId(GetCurrentProcessId(), &ours) || theirs != ours) return 2;
        owner.value = OpenProcess(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
        if (!owner.value || WaitForSingleObject(owner.value, 0) != WAIT_TIMEOUT) return 2;
    }
#else
    constexpr bool session = false;
#endif
    if (argc == 2 && strcmp(argv[1], "--restore") == 0) {
        SavedSource saved;
        FILE* f = nullptr;
        if (fopen_s(&f, "native-source-backup.bin", "rb")) return 1;
        size_t n = fread(&saved, 1, sizeof(saved), f);
        fclose(f);
        return n == sizeof(saved) && Restore(saved) ? 0 : 1;
    }
    bool managed = session || (argc >= 2 && strcmp(argv[1], "--hold-managed") == 0);
    bool apply = managed || (argc == 2 && strcmp(argv[1], "--hold") == 0);
    unsigned long holdSeconds = 45;
    if (managed && !session && argc == 3) {
        char* end = nullptr;
        holdSeconds = strtoul(argv[2], &end, 10);
        if (!*argv[2] || *end || holdSeconds < 45 || holdSeconds > 630) return 2;
    }
    if ((argc > 1 && !apply) || argc > (managed ? 3 : 2)) return 2;
    Configuration c;
    if (!c.Read()) { puts("Verified un-cloned headset display absent."); return 1; }
    auto& p = c.paths[c.chosen];
    auto& source = c.modes[p.sourceInfo.modeInfoIdx].sourceMode;
    auto signal = c.modes[p.targetInfo.modeInfoIdx].targetMode.targetVideoSignalInfo;
    double hz = signal.vSyncFreq.Denominator ? double(signal.vSyncFreq.Numerator) / signal.vSyncFreq.Denominator : 0;
    printf("Original source=%ux%u scaling=%u target=%ux%u %.6fHz\n", source.width, source.height, p.targetInfo.scaling, signal.activeSize.cx, signal.activeSize.cy, hz);
    if (signal.activeSize.cx != 1440 || signal.activeSize.cy != 2560 || hz < 79 || hz > 81) { puts("Native physical signal required; no changes."); return 1; }
    SavedSource saved;
    saved.adapter = p.sourceInfo.adapterId; saved.sourceId = p.sourceInfo.id;
    saved.source = source; saved.scaling = p.targetInfo.scaling;
    source.width = 1440; source.height = 2560;
    p.targetInfo.scaling = DISPLAYCONFIG_SCALING_IDENTITY;
    LONG r = c.Submit(SDC_VALIDATE);
    printf("Native desktop surface validation=%ld\n", r);
    if (r || !apply) return r ? 1 : 0;
    HANDLE backup = CreateFileW(L"native-source-backup.bin", GENERIC_WRITE, 0, nullptr, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (backup == INVALID_HANDLE_VALUE) return 1;
    DWORD written = 0;
    BOOL wrote = WriteFile(backup, &saved, sizeof(saved), &written, nullptr);
    FlushFileBuffers(backup);
    CloseHandle(backup);
    if (!wrote || written != sizeof(saved)) return 1;
    r = c.Submit(SDC_APPLY);
    printf("Native desktop surface apply=%ld\n", r);
    if (r) return 1;
    bool confirmed = false;
    Configuration after;
    if (after.Read()) {
        const auto& a = after.paths[after.chosen];
        const auto& s = after.modes[a.sourceInfo.modeInfoIdx].sourceMode;
        const auto& t = after.modes[a.targetInfo.modeInfoIdx].targetMode.targetVideoSignalInfo;
        printf("Applied source=%ux%u scaling=%u target=%ux%u clock=%llu\n", s.width, s.height, a.targetInfo.scaling, t.activeSize.cx, t.activeSize.cy, t.pixelRate);
        confirmed = s.width == 1440 && s.height == 2560 && a.targetInfo.scaling == DISPLAYCONFIG_SCALING_IDENTITY &&
            memcmp(&t, &signal, sizeof(signal)) == 0;
    }
    if (confirmed) {
        FILE* ready = nullptr;
        if (fopen_s(&ready, "native-source-ready.txt", "w") == 0) { fputs("Native desktop and unchanged physical timing verified.\n", ready); fclose(ready); }
        const ULONGLONG end = GetTickCount64() + holdSeconds * 1000ULL;
        while ((session || GetTickCount64() < end) && GetFileAttributesW(L"native-source-stop.txt") == INVALID_FILE_ATTRIBUTES) {
#ifdef ARC_RIFT_MANUAL_SESSION
            if (session && WaitForSingleObject(owner.value, 0) != WAIT_TIMEOUT) {
                puts("Harness owner exited: independent session recovery/full EDID rollback REQUIRED; no unsafe source-only restore.");
                return 1;
            }
#endif
            Sleep(100);
        }
        if (managed && GetFileAttributesW(L"native-source-stop.txt") != INVALID_FILE_ATTRIBUTES) {
            puts("Managed stop: source-only restore intentionally skipped; harness full EDID/runtime rollback REQUIRED.");
            return 0;
        }
    }
    bool restored = Restore(saved);
    return confirmed && restored ? 0 : 1;
}
