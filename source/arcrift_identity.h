#pragma once
// ArcRift release 1.1: per-machine identity, read from "arcrift-identity.txt" next to the module.
// Written by ArcRift Control's Setup / the session script. Format (one per line):
//   target=12345
//   monitor=DISPLAY#MS_0001#7&0000000&0&UID12345#
//   gpu=8086:56A0            (may repeat)
// If the file is missing or incomplete, nothing is matched, so no display is touched.
#include <windows.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cwchar>
#include <cwctype>
#include <utility>
#include <vector>

struct ArcRiftIdentity {
    UINT32 target = 0;
    wchar_t monitor[256]{};
    std::vector<std::pair<UINT, UINT>> gpus;
    bool valid = false;
    bool GpuAllowed(UINT vendor, UINT device) const {
        for (const auto& g : gpus) if (g.first == vendor && g.second == device) return true;
        return false;
    }
    // Case-insensitive: Windows reports these IDs with mixed letter case.
    bool MonitorMatches(const wchar_t* devicePath) const {
        if (!valid || !devicePath) return false;
        wchar_t a[512]{}, b[256]{};
        for (size_t i = 0; i + 1 < 512 && devicePath[i]; ++i) a[i] = static_cast<wchar_t>(towupper(devicePath[i]));
        for (size_t i = 0; i + 1 < 256 && monitor[i]; ++i) b[i] = static_cast<wchar_t>(towupper(monitor[i]));
        return wcsstr(a, b) != nullptr;
    }
};

inline ArcRiftIdentity ArcRiftLoadIdentity(HMODULE module) {
    ArcRiftIdentity id;
    wchar_t path[MAX_PATH]{};
    DWORD n = GetModuleFileNameW(module, path, MAX_PATH);
    if (!n || n >= MAX_PATH) return id;
    wchar_t* last = wcsrchr(path, L'\\');
    if (!last || wcscpy_s(last + 1, MAX_PATH - (last + 1 - path), L"arcrift-identity.txt")) return id;
    FILE* f = nullptr;
    if (_wfopen_s(&f, path, L"r") || !f) return id;
    char line[512];
    while (fgets(line, sizeof line, f)) {
        size_t len = strlen(line);
        while (len && (line[len - 1] == '\n' || line[len - 1] == '\r' || line[len - 1] == ' ')) line[--len] = 0;
        if (!strncmp(line, "target=", 7)) id.target = strtoul(line + 7, nullptr, 10);
        else if (!strncmp(line, "monitor=", 8)) MultiByteToWideChar(CP_UTF8, 0, line + 8, -1, id.monitor, 256);
        else if (!strncmp(line, "gpu=", 4)) {
            unsigned vendor = 0, device = 0;
            if (sscanf_s(line + 4, "%x:%x", &vendor, &device) == 2) id.gpus.push_back({vendor, device});
        }
    }
    fclose(f);
    id.valid = id.target != 0 && _wcsnicmp(id.monitor, L"DISPLAY#", 8) == 0 && !id.gpus.empty();
    return id;
}
