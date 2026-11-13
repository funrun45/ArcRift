// arcrift_boundary.exe: a room boundary for ArcRift sessions.
//
// On Intel Arc, Meta's Guardian cannot be set up: its setup screen lives in Meta's Dash, and Dash needs Vulkan, which
// Meta does not support on Arc (tested 2026-11-04: Dash quits with "Failed to configure Rendering Code: -4"). So SteamVR
// only gets a 1x1 m placeholder. This helper lets you trace your play space with a controller trigger (headset pushed
// up on your forehead so you see the room and its cameras still track the controller), then:
//   * hands the outline to SteamVR's live chaperone, so games see the real play area, and
//   * draws the boundary itself as world-locked SteamVR overlay walls that fade in as you get close (like Guardian),
//     because SteamVR does not draw its own chaperone for Oculus headsets.
//
// Commands (run as the normal user while SteamVR is running; ArcRift Control starts them):
//   arcrift_boundary.exe box [width] [depth]  quick box: countdown, then a width x depth m rectangle (default 2 x 2)
//                                is placed around the headset, lined up with the way it faces. Needs no controller.
//   arcrift_boundary.exe draw    hold a controller trigger and trace the edge (headset pushed up on the forehead)
//   arcrift_boundary.exe drawwalk  older method: countdown, then walk the edge holding the headset
//   arcrift_boundary.exe apply   reuse the saved outline, lined up from the starting spot (controller + trigger)
//   arcrift_boundary.exe clear   remove it and put SteamVR's chaperone back the way it was
//   arcrift_boundary.exe finish  ask a running "draw" to finish now with what it has
//
// Status for ArcRift Control: boundary-status.json in this folder. Saved outline: boundary-saved.txt. Log:
// boundary-log.txt. Nothing is written to SteamVR or Meta settings on disk: the boundary lives in SteamVR's live
// (in-memory) chaperone, which Meta's driver recreates when SteamVR starts, and "clear" restores the exact previous
// live chaperone. Uses SteamVR's own openvr_api.dll, loaded at runtime.
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <tlhelp32.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

#include "openvr/openvr.h"

namespace {

const float kWallHeight = 2.2f;      // m, overlay walls and chaperone quads
const float kSampleStep = 0.10f;     // m between recorded points
const float kCloseDistance = 0.45f;  // m from the start point that closes the loop
const float kMinLoopLength = 3.0f;   // m walked before the loop may close
const float kMinArea = 1.0f;         // m2
const float kFadeStart = 0.75f;      // m: walls start to appear
const float kFadeFull = 0.30f;       // m: walls fully visible
const int kCountdownSeconds = 15;
const int kBoxCountdownSeconds = 10;
const float kBoxMin = 1.0f, kBoxMax = 8.0f; // m, each side of the quick box
const int kMaxWalls = 48;
const DWORD kDrawTimeoutMs = 5 * 60 * 1000;

struct P2 { float x, z; };

std::wstring g_root;
HANDLE g_stopEvent = nullptr;

// ---------- small helpers ----------

std::wstring Widen(const std::string &s) {
    if (s.empty()) return {};
    int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), nullptr, 0);
    std::wstring w(n, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), &w[0], n);
    return w;
}

std::string Narrow(const std::wstring &w) {
    if (w.empty()) return {};
    int n = WideCharToMultiByte(CP_UTF8, 0, w.data(), (int)w.size(), nullptr, 0, nullptr, nullptr);
    std::string s(n, '\0');
    WideCharToMultiByte(CP_UTF8, 0, w.data(), (int)w.size(), &s[0], n, nullptr, nullptr);
    return s;
}

std::wstring RootFile(const wchar_t *name) { return g_root + L"\\" + name; }

void Log(const std::string &line) {
    std::ofstream f(RootFile(L"boundary-log.txt"), std::ios::app);
    SYSTEMTIME t; GetLocalTime(&t);
    char stamp[64];
    sprintf_s(stamp, "%04d-%02d-%02d %02d:%02d:%02d ", t.wYear, t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond);
    f << stamp << line << "\n";
}

std::string JsonEscape(const std::string &s) {
    std::string o;
    for (char c : s) {
        if (c == '"' || c == '\\') { o += '\\'; o += c; }
        else if (c == '\n') o += "\\n";
        else if ((unsigned char)c < 0x20) o += ' ';
        else o += c;
    }
    return o;
}

// state: countdown | recording | active | error | off | cleared | cancelled
void Status(const std::string &state, const std::string &message, int points = 0, float length = 0, float area = 0, int walls = 0) {
    std::ostringstream j;
    j << "{\"state\":\"" << state << "\",\"message\":\"" << JsonEscape(message) << "\",\"points\":" << points
      << ",\"lengthM\":" << std::round(length * 10) / 10 << ",\"areaM2\":" << std::round(area * 10) / 10
      << ",\"walls\":" << walls << ",\"pid\":" << GetCurrentProcessId() << ",\"time\":" << (long long)time(nullptr) << "}";
    std::wstring tmp = RootFile(L"boundary-status.json.tmp");
    { std::ofstream f(tmp, std::ios::trunc | std::ios::binary); f << j.str(); }
    MoveFileExW(tmp.c_str(), RootFile(L"boundary-status.json").c_str(), MOVEFILE_REPLACE_EXISTING);
}

bool StopRequested() { return g_stopEvent && WaitForSingleObject(g_stopEvent, 0) == WAIT_OBJECT_0; }

bool TakeFinishRequest() {
    std::wstring f = RootFile(L"boundary-finish.txt");
    if (GetFileAttributesW(f.c_str()) == INVALID_FILE_ATTRIBUTES) return false;
    DeleteFileW(f.c_str());
    return true;
}

DWORD ProcessId(const wchar_t *exe) {
    DWORD pid = 0;
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE_VALUE) return 0;
    PROCESSENTRY32W e{}; e.dwSize = sizeof(e);
    for (BOOL ok = Process32FirstW(snap, &e); ok; ok = Process32NextW(snap, &e)) {
        if (_wcsicmp(e.szExeFile, exe) == 0) { pid = e.th32ProcessID; break; }
    }
    CloseHandle(snap);
    return pid;
}

// ---------- geometry ----------

float Dist(P2 a, P2 b) { return std::hypot(a.x - b.x, a.z - b.z); }

float SegDist(P2 p, P2 a, P2 b) {
    float dx = b.x - a.x, dz = b.z - a.z, l2 = dx * dx + dz * dz;
    float t = l2 > 0 ? ((p.x - a.x) * dx + (p.z - a.z) * dz) / l2 : 0;
    t = std::clamp(t, 0.0f, 1.0f);
    return Dist(p, {a.x + t * dx, a.z + t * dz});
}

bool Inside(const std::vector<P2> &poly, P2 p) {
    bool in = false;
    for (size_t i = 0, j = poly.size() - 1; i < poly.size(); j = i++) {
        if (((poly[i].z > p.z) != (poly[j].z > p.z)) &&
            (p.x < (poly[j].x - poly[i].x) * (p.z - poly[i].z) / (poly[j].z - poly[i].z) + poly[i].x)) in = !in;
    }
    return in;
}

float Area(const std::vector<P2> &poly) {
    double a = 0;
    for (size_t i = 0, j = poly.size() - 1; i < poly.size(); j = i++) a += (double)poly[j].x * poly[i].z - (double)poly[i].x * poly[j].z;
    return (float)std::fabs(a / 2);
}

void Simplify(const std::vector<P2> &in, size_t a, size_t b, float eps, std::vector<bool> &keep) {
    if (b <= a + 1) return;
    float best = -1; size_t idx = a;
    for (size_t i = a + 1; i < b; i++) { float d = SegDist(in[i], in[a], in[b]); if (d > best) { best = d; idx = i; } }
    if (best > eps) { keep[idx] = true; Simplify(in, a, idx, eps, keep); Simplify(in, idx, b, eps, keep); }
}

// Closed outline from the walked path: Douglas-Peucker, then fewer walls if needed.
std::vector<P2> Outline(const std::vector<P2> &path) {
    std::vector<P2> pts = path;
    while (pts.size() > 3 && Dist(pts.back(), pts.front()) < kSampleStep) pts.pop_back();
    for (float eps = 0.05f; eps < 1.0f; eps *= 1.5f) {
        std::vector<bool> keep(pts.size(), false);
        keep.front() = keep.back() = true;
        Simplify(pts, 0, pts.size() - 1, eps, keep);
        std::vector<P2> out;
        for (size_t i = 0; i < pts.size(); i++) if (keep[i]) out.push_back(pts[i]);
        if (out.size() > 2 && Dist(out.back(), out.front()) < 0.15f) out.pop_back();
        if ((int)out.size() <= kMaxWalls) return out;
    }
    return pts;
}

// Quick box: a width x depth rectangle centred on c. yaw is the heading from DevicePose, so the facing direction is
// (sin yaw, cos yaw) in (x,z) and "right" is (-cos yaw, sin yaw); depth runs along the facing direction.
std::vector<P2> BoxOutline(P2 c, float yaw, float width, float depth) {
    float fx = std::sin(yaw), fz = std::cos(yaw), rx = -fz, rz = fx, hw = width / 2, hd = depth / 2;
    return {{c.x - rx * hw - fx * hd, c.z - rz * hw - fz * hd},
            {c.x + rx * hw - fx * hd, c.z + rz * hw - fz * hd},
            {c.x + rx * hw + fx * hd, c.z + rz * hw + fz * hd},
            {c.x - rx * hw + fx * hd, c.z - rz * hw + fz * hd}};
}

// ---------- rigid transforms (1.3: box play area) ----------
// OpenVR 3x4 matrices: rotation in the left 3x3, translation in the last column. a*b applies b first.

const float kPi = 3.14159265f;

vr::HmdMatrix34_t Mul(const vr::HmdMatrix34_t &a, const vr::HmdMatrix34_t &b) {
    vr::HmdMatrix34_t r{};
    for (int i = 0; i < 3; i++) {
        for (int j = 0; j < 3; j++) r.m[i][j] = a.m[i][0] * b.m[0][j] + a.m[i][1] * b.m[1][j] + a.m[i][2] * b.m[2][j];
        r.m[i][3] = a.m[i][0] * b.m[0][3] + a.m[i][1] * b.m[1][3] + a.m[i][2] * b.m[2][3] + a.m[i][3];
    }
    return r;
}

vr::HmdMatrix34_t Inverse(const vr::HmdMatrix34_t &a) {
    vr::HmdMatrix34_t r{};
    for (int i = 0; i < 3; i++)
        for (int j = 0; j < 3; j++) r.m[i][j] = a.m[j][i];
    for (int i = 0; i < 3; i++) r.m[i][3] = -(r.m[i][0] * a.m[0][3] + r.m[i][1] * a.m[1][3] + r.m[i][2] * a.m[2][3]);
    return r;
}

// Where a floor point (x, 0, z) lands, as (x, z).
P2 MapXZ(const vr::HmdMatrix34_t &m, float x, float z) {
    return {m.m[0][0] * x + m.m[0][2] * z + m.m[0][3], m.m[2][0] * x + m.m[2][2] * z + m.m[2][3]};
}

// Heading of a pose, same convention as DevicePose: facing direction is (sin yaw, cos yaw) in (x, z).
float MatrixYaw(const vr::HmdMatrix34_t &m) { return std::atan2(-m.m[0][2], -m.m[2][2]); }

float AngleDiff(float a, float b) {
    float d = std::fmod(a - b, 2 * kPi);
    if (d > kPi) d -= 2 * kPi;
    if (d < -kPi) d += 2 * kPi;
    return d;
}

bool SamePose(const vr::HmdMatrix34_t &a, const vr::HmdMatrix34_t &b, float metres, float radians) {
    float dx = a.m[0][3] - b.m[0][3], dy = a.m[1][3] - b.m[1][3], dz = a.m[2][3] - b.m[2][3];
    return std::sqrt(dx * dx + dy * dy + dz * dz) < metres && std::fabs(AngleDiff(MatrixYaw(a), MatrixYaw(b))) < radians;
}

// The quick box's own space, as a pose in the space (c, yaw) were measured in: origin at the box centre on the floor,
// -Z along the facing direction (like every OpenVR pose), X to the right.
vr::HmdMatrix34_t BoxFrame(P2 c, float yaw) {
    float fx = std::sin(yaw), fz = std::cos(yaw);
    vr::HmdMatrix34_t t{};
    t.m[0][0] = -fz; t.m[0][2] = -fx; t.m[0][3] = c.x;
    t.m[1][1] = 1;
    t.m[2][0] = fx;  t.m[2][2] = -fz; t.m[2][3] = c.z;
    return t;
}

// Corners of a width x depth box given its pose in some space; same corner order as BoxOutline.
std::vector<P2> BoxCorners(const vr::HmdMatrix34_t &boxToSpace, float width, float depth) {
    float hw = width / 2, hd = depth / 2;
    return {MapXZ(boxToSpace, -hw, hd), MapXZ(boxToSpace, hw, hd), MapXZ(boxToSpace, hw, -hd), MapXZ(boxToSpace, -hw, -hd)};
}

// Largest play-area rectangle centred on the standing origin that fits inside the outline (0 if none).
void PlayArea(const std::vector<P2> &poly, float &sx, float &sz) {
    sx = sz = 0;
    if (!Inside(poly, {0, 0})) return;
    float minX = 1e9f, maxX = -1e9f, minZ = 1e9f, maxZ = -1e9f;
    for (P2 p : poly) { minX = std::min(minX, p.x); maxX = std::max(maxX, p.x); minZ = std::min(minZ, p.z); maxZ = std::max(maxZ, p.z); }
    float hx0 = std::min(-minX, maxX), hz0 = std::min(-minZ, maxZ);
    for (float s = 1.0f; s > 0.05f; s -= 0.05f) {
        float hx = hx0 * s, hz = hz0 * s;
        P2 c[4] = {{-hx, -hz}, {hx, -hz}, {hx, hz}, {-hx, hz}};
        bool ok = true;
        for (P2 p : c) if (!Inside(poly, p)) ok = false;
        for (P2 p : poly) if (std::fabs(p.x) < hx && std::fabs(p.z) < hz) ok = false;
        if (ok) { sx = 2 * hx; sz = 2 * hz; return; }
    }
}

// ---------- OpenVR ----------

typedef uint32_t(VR_CALLTYPE *PfnInit)(vr::EVRInitError *, vr::EVRApplicationType, const char *);
typedef void(VR_CALLTYPE *PfnShutdown)();
typedef void *(VR_CALLTYPE *PfnGetInterface)(const char *, vr::EVRInitError *);

PfnInit g_init = nullptr;
PfnShutdown g_shutdown = nullptr;
PfnGetInterface g_getInterface = nullptr;
vr::IVRSystem *g_system = nullptr;
vr::IVRChaperone *g_chaperone = nullptr;
vr::IVRChaperoneSetup *g_setup = nullptr;
vr::IVROverlay *g_overlay = nullptr;

// SteamVR records its install folder in %LOCALAPPDATA%\openvr\openvrpaths.vrpath ("runtime": ["...SteamVR"]).
std::wstring OpenVrDllPath() {
    wchar_t local[MAX_PATH];
    if (!GetEnvironmentVariableW(L"LOCALAPPDATA", local, MAX_PATH)) return {};
    std::ifstream f(std::wstring(local) + L"\\openvr\\openvrpaths.vrpath", std::ios::binary);
    std::string text((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
    size_t k = text.find("\"runtime\"");
    if (k == std::string::npos) return {};
    size_t q1 = text.find('"', text.find('[', k) + 1);
    if (q1 == std::string::npos) return {};
    std::string path;
    for (size_t i = q1 + 1; i < text.size() && text[i] != '"'; i++) {
        if (text[i] == '\\' && i + 1 < text.size()) { path += text[++i]; } else path += text[i];
    }
    return Widen(path) + L"\\bin\\win64\\openvr_api.dll";
}

bool InitVR(vr::EVRApplicationType type, std::string &err) {
    std::wstring dll = OpenVrDllPath();
    HMODULE m = dll.empty() ? nullptr : LoadLibraryExW(dll.c_str(), nullptr, LOAD_WITH_ALTERED_SEARCH_PATH);
    if (!m) { err = "SteamVR's openvr_api.dll was not found (" + Narrow(dll) + ")."; return false; }
    g_init = (PfnInit)GetProcAddress(m, "VR_InitInternal2");
    g_shutdown = (PfnShutdown)GetProcAddress(m, "VR_ShutdownInternal");
    g_getInterface = (PfnGetInterface)GetProcAddress(m, "VR_GetGenericInterface");
    if (!g_init || !g_shutdown || !g_getInterface) { err = "SteamVR's openvr_api.dll is missing expected functions."; return false; }
    vr::EVRInitError e = vr::VRInitError_None;
    g_init(&e, type, nullptr);
    if (e != vr::VRInitError_None) { err = "Could not connect to SteamVR (error " + std::to_string((int)e) + ")."; return false; }
    g_system = (vr::IVRSystem *)g_getInterface(vr::IVRSystem_Version, &e);
    g_chaperone = (vr::IVRChaperone *)g_getInterface(vr::IVRChaperone_Version, &e);
    g_setup = (vr::IVRChaperoneSetup *)g_getInterface(vr::IVRChaperoneSetup_Version, &e);
    if (type == vr::VRApplication_Overlay) g_overlay = (vr::IVROverlay *)g_getInterface(vr::IVROverlay_Version, &e);
    if (!g_system || !g_chaperone || !g_setup || (type == vr::VRApplication_Overlay && !g_overlay)) {
        err = "This SteamVR version does not offer the needed interfaces.";
        g_shutdown();
        return false;
    }
    return true;
}

// Position (x,z) and heading of a tracked device; the headset and Touch controllers point down their -Z axis.
bool DevicePose(uint32_t device, P2 &pos, float &yaw) {
    if (device >= vr::k_unMaxTrackedDeviceCount) return false;
    vr::TrackedDevicePose_t poses[vr::k_unMaxTrackedDeviceCount];
    g_system->GetDeviceToAbsoluteTrackingPose(vr::TrackingUniverseStanding, 0, poses, device + 1);
    if (!poses[device].bPoseIsValid || poses[device].eTrackingResult != vr::TrackingResult_Running_OK) return false;
    const vr::HmdMatrix34_t &m = poses[device].mDeviceToAbsoluteTracking;
    pos = {m.m[0][3], m.m[2][3]};
    yaw = std::atan2(-m.m[0][2], -m.m[2][2]);
    return true;
}

bool HmdPose(P2 &pos, float &yaw) { return DevicePose(vr::k_unTrackedDeviceIndex_Hmd, pos, yaw); }

// What SteamVR sees right now, for the log: how many controllers, how many of them tracked, and the headset.
// Returns the number of tracked controllers.
int DeviceSummary(std::string *text = nullptr) {
    vr::TrackedDevicePose_t poses[vr::k_unMaxTrackedDeviceCount];
    g_system->GetDeviceToAbsoluteTrackingPose(vr::TrackingUniverseStanding, 0, poses, vr::k_unMaxTrackedDeviceCount);
    int controllers = 0, tracked = 0;
    for (uint32_t i = 1; i < vr::k_unMaxTrackedDeviceCount; i++) {
        if (g_system->GetTrackedDeviceClass(i) != vr::TrackedDeviceClass_Controller) continue;
        controllers++;
        if (poses[i].bPoseIsValid && poses[i].eTrackingResult == vr::TrackingResult_Running_OK) tracked++;
    }
    if (text) {
        const vr::TrackedDevicePose_t &h = poses[vr::k_unTrackedDeviceIndex_Hmd];
        bool hmdOk = h.bPoseIsValid && h.eTrackingResult == vr::TrackingResult_Running_OK;
        char buf[200];
        sprintf_s(buf, "%d controller(s), %d tracked; headset %s (height %.2f m, activity level %d).", controllers, tracked,
                  hmdOk ? "tracked" : "NOT tracked", hmdOk ? h.mDeviceToAbsoluteTracking.m[1][3] : 0.0f,
                  (int)g_system->GetTrackedDeviceActivityLevel(vr::k_unTrackedDeviceIndex_Hmd));
        *text = buf;
    }
    return tracked;
}

// Height (m) the overlay walls start at. Without Guardian, Meta has no measured floor, so y = 0 can be well off the
// real floor. If the headset is not at a believable head height above y = 0, hang the walls around the headset instead.
float WallBase() {
    vr::TrackedDevicePose_t pose;
    g_system->GetDeviceToAbsoluteTrackingPose(vr::TrackingUniverseStanding, 0, &pose, 1);
    if (!pose.bPoseIsValid) { Log("Headset height unknown; walls start at y = 0."); return 0; }
    float y = pose.mDeviceToAbsoluteTracking.m[1][3];
    float base = (y < 0.9f || y > 2.2f) ? y - 1.6f : 0.0f;
    char buf[160];
    sprintf_s(buf, "Headset height %.2f m; walls from %.2f to %.2f m.", y, base, base + kWallHeight);
    Log(buf);
    return base;
}

// ---------- controller trigger (1.2.1) ----------
// SteamVR Input action "draw" bound to either trigger, with the legacy controller state as a fallback.

vr::IVRInput *g_input = nullptr;
vr::VRActionSetHandle_t g_actionSet = vr::k_ulInvalidActionSetHandle;
vr::VRActionHandle_t g_drawAction = vr::k_ulInvalidActionHandle;
vr::VRActionHandle_t g_hapticAction = vr::k_ulInvalidActionHandle;
vr::VRInputValueHandle_t g_lastOrigin = vr::k_ulInvalidInputValueHandle;
bool g_inputReady = false;
bool g_legacyTriggerSeen = false, g_actionTriggerSeen = false;

void WriteRootText(const wchar_t *name, const char *text) {
    std::ofstream f(RootFile(name), std::ios::binary | std::ios::trunc);
    f << text;
}

void InitInput() {
    vr::EVRInitError e = vr::VRInitError_None;
    g_input = (vr::IVRInput *)g_getInterface(vr::IVRInput_Version, &e);
    if (!g_input) { Log("SteamVR Input not available; using the legacy controller state."); return; }
    WriteRootText(L"boundary-actions.json", R"JSON({
  "default_bindings": [ { "controller_type": "oculus_touch", "binding_url": "boundary-bindings-touch.json" } ],
  "actions": [
    { "name": "/actions/boundary/in/draw", "type": "boolean" },
    { "name": "/actions/boundary/out/haptic", "type": "vibration" }
  ],
  "action_sets": [ { "name": "/actions/boundary", "usage": "leftright" } ],
  "localization": [ { "language_tag": "en_US", "/actions/boundary": "ArcRift boundary",
    "/actions/boundary/in/draw": "Draw boundary (hold)", "/actions/boundary/out/haptic": "Drawing feedback" } ]
}
)JSON");
    WriteRootText(L"boundary-bindings-touch.json", R"JSON({
  "controller_type": "oculus_touch",
  "name": "ArcRift boundary defaults",
  "bindings": {
    "/actions/boundary": {
      "sources": [
        { "path": "/user/hand/left/input/trigger", "mode": "button", "inputs": { "click": { "output": "/actions/boundary/in/draw" } } },
        { "path": "/user/hand/right/input/trigger", "mode": "button", "inputs": { "click": { "output": "/actions/boundary/in/draw" } } }
      ],
      "haptics": [
        { "output": "/actions/boundary/out/haptic", "path": "/user/hand/left/output/haptic" },
        { "output": "/actions/boundary/out/haptic", "path": "/user/hand/right/output/haptic" }
      ]
    }
  }
}
)JSON");
    std::string manifest = Narrow(RootFile(L"boundary-actions.json"));
    vr::EVRInputError ie = g_input->SetActionManifestPath(manifest.c_str());
    if (ie == vr::VRInputError_None) ie = g_input->GetActionSetHandle("/actions/boundary", &g_actionSet);
    if (ie == vr::VRInputError_None) ie = g_input->GetActionHandle("/actions/boundary/in/draw", &g_drawAction);
    if (ie == vr::VRInputError_None) g_input->GetActionHandle("/actions/boundary/out/haptic", &g_hapticAction);
    g_inputReady = ie == vr::VRInputError_None;
    Log(std::string("SteamVR Input ") + (g_inputReady ? "ready" : "failed (error " + std::to_string((int)ie) + "); using the legacy controller state"));
}

// Returns true while a trigger is held; device = that controller's tracked-device index (0 if unknown).
bool TriggerDown(uint32_t &device) {
    device = 0;
    if (g_inputReady) {
        vr::VRActiveActionSet_t set{};
        set.ulActionSet = g_actionSet;
        set.ulRestrictedToDevice = vr::k_ulInvalidInputValueHandle;
        g_input->UpdateActionState(&set, sizeof(set), 1);
        vr::InputDigitalActionData_t d{};
        if (g_input->GetDigitalActionData(g_drawAction, &d, sizeof(d), vr::k_ulInvalidInputValueHandle) == vr::VRInputError_None &&
            d.bActive && d.bState) {
            vr::InputOriginInfo_t info{};
            if (g_input->GetOriginTrackedDeviceInfo(d.activeOrigin, &info, sizeof(info)) == vr::VRInputError_None) device = info.trackedDeviceIndex;
            g_lastOrigin = d.activeOrigin;
            if (!g_actionTriggerSeen) { g_actionTriggerSeen = true; Log("Trigger seen through SteamVR Input."); }
            return true;
        }
    }
    for (uint32_t i = 1; i < vr::k_unMaxTrackedDeviceCount; i++) {
        if (g_system->GetTrackedDeviceClass(i) != vr::TrackedDeviceClass_Controller) continue;
        vr::VRControllerState_t s{};
        if (!g_system->GetControllerState(i, &s, sizeof(s))) continue;
        if ((s.ulButtonPressed & vr::ButtonMaskFromId(vr::k_EButton_SteamVR_Trigger)) || s.rAxis[1].x > 0.7f) {
            device = i;
            if (!g_legacyTriggerSeen) { g_legacyTriggerSeen = true; Log("Trigger seen through the legacy controller state."); }
            return true;
        }
    }
    return false;
}

void Buzz(uint32_t device, float seconds, float amplitude) {
    if (g_inputReady && g_hapticAction != vr::k_ulInvalidActionHandle && g_lastOrigin != vr::k_ulInvalidInputValueHandle)
        g_input->TriggerHapticVibrationAction(g_hapticAction, 0, seconds, 160, amplitude, g_lastOrigin);
    else if (device) g_system->TriggerHapticPulse(device, 0, (unsigned short)std::min(3999.0f, seconds * 1000000.0f));
}

// Positions (x,z) of the headset and controllers, for the fade-in distance.
std::vector<P2> TrackedPoints() {
    vr::TrackedDevicePose_t poses[vr::k_unMaxTrackedDeviceCount];
    g_system->GetDeviceToAbsoluteTrackingPose(vr::TrackingUniverseStanding, 0, poses, vr::k_unMaxTrackedDeviceCount);
    std::vector<P2> out;
    for (uint32_t i = 0; i < vr::k_unMaxTrackedDeviceCount; i++) {
        if (!poses[i].bPoseIsValid) continue;
        vr::ETrackedDeviceClass c = g_system->GetTrackedDeviceClass(i);
        if (c != vr::TrackedDeviceClass_HMD && c != vr::TrackedDeviceClass_Controller) continue;
        out.push_back({poses[i].mDeviceToAbsoluteTracking.m[0][3], poses[i].mDeviceToAbsoluteTracking.m[2][3]});
    }
    return out;
}

// The live chaperone before ArcRift first changed it during this SteamVR run, so "clear" can put it back exactly.
void BackupLiveChaperone() {
    DWORD server = ProcessId(L"vrserver.exe");
    std::wstring path = RootFile(L"boundary-chaperone-backup.txt");
    {
        std::ifstream f(path, std::ios::binary);
        DWORD pid = 0;
        if (f >> pid && pid == server) return; // already saved for this SteamVR run
    }
    uint32_t len = 0;
    g_setup->ExportLiveToBuffer(nullptr, &len);
    if (!len) { Log("Could not export the live chaperone for backup."); return; }
    std::string buf(len, '\0');
    if (!g_setup->ExportLiveToBuffer(&buf[0], &len)) { Log("Live chaperone export failed."); return; }
    buf.resize(strnlen(buf.c_str(), buf.size()));
    std::ofstream f(path, std::ios::binary | std::ios::trunc);
    f << server << "\n" << buf;
    Log("Saved the previous live chaperone (" + std::to_string(buf.size()) + " bytes).");
}

// 1.3: a quick box as SteamVR's play area. SteamVR's play area is always a rectangle centred on its standing origin and
// lined up with its axes, so a box placed anywhere else, or turned, used to give games only the small rectangle that
// fitted both (1.37 x 1.02 m for a 2 x 2 m box in one session). Now the standing origin is moved to the box centre,
// facing the way the headset faced; the box is then exactly SteamVR's play area. The box is remembered in raw tracking
// space, so it can be put back, or kept in place, if something moves the standing origin again.
struct BoxAnchor {
    bool active = false;        // the origin move was checked and worked; Keep watches it
    bool reseat = false;        // commits also set the standing origin to the box
    int resets = 0;             // times the standing origin was moved away again
    float w = 0, d = 0;
    vr::HmdMatrix34_t toRaw{};  // box centre and facing, in raw tracking space
} g_box;

// SteamVR's live standing origin as a pose in raw tracking space.
bool LiveStandingToRaw(vr::HmdMatrix34_t &s) {
    g_setup->RevertWorkingCopy();
    return g_setup->GetWorkingStandingZeroPoseToRawTrackingPose(&s);
}

// True once the headset reads as standing at "where" facing "yaw" (within 15 cm and 10 degrees).
bool WaitHeadsetAt(P2 where, float yaw, DWORD ms) {
    for (DWORD began = GetTickCount(); GetTickCount() - began < ms; Sleep(40)) {
        P2 p; float y;
        if (HmdPose(p, y) && Dist(p, where) < 0.15f && std::fabs(AngleDiff(y, yaw)) < 0.17f) return true;
    }
    return false;
}

// The standing origin before ArcRift first moved it during this SteamVR run, so "clear" can put it back.
void BackupStandingOrigin(const vr::HmdMatrix34_t &s) {
    DWORD server = ProcessId(L"vrserver.exe");
    std::wstring path = RootFile(L"boundary-origin-backup.txt");
    {
        std::ifstream f(path);
        DWORD pid = 0;
        if (f >> pid && pid == server) return; // already saved for this SteamVR run
    }
    std::ofstream f(path, std::ios::trunc);
    f.precision(9);
    f << server << "\n";
    for (int i = 0; i < 3; i++) for (int j = 0; j < 4; j++) f << s.m[i][j] << (j == 3 ? "\n" : " ");
}

bool CommitChaperone(const std::vector<P2> &poly) {
    std::vector<vr::HmdQuad_t> quads(poly.size());
    for (size_t i = 0; i < poly.size(); i++) {
        P2 a = poly[i], b = poly[(i + 1) % poly.size()];
        quads[i].vCorners[0] = {{a.x, 0, a.z}};
        quads[i].vCorners[1] = {{a.x, kWallHeight, a.z}};
        quads[i].vCorners[2] = {{b.x, kWallHeight, b.z}};
        quads[i].vCorners[3] = {{b.x, 0, b.z}};
    }
    float sx, sz;
    if (g_box.reseat) { sx = g_box.w; sz = g_box.d; } else PlayArea(poly, sx, sz);
    g_setup->RevertWorkingCopy();
    if (g_box.reseat) g_setup->SetWorkingStandingZeroPoseToRawTrackingPose(&g_box.toRaw);
    g_setup->SetWorkingCollisionBoundsInfo(quads.data(), (uint32_t)quads.size());
    if (sx > 0 && sz > 0) g_setup->SetWorkingPlayAreaSize(sx, sz);
    bool ok = g_setup->CommitWorkingCopy(vr::EChaperoneConfigFile_Live);
    Log(std::string("Chaperone commit ") + (ok ? "ok" : "FAILED") + ": " + std::to_string(quads.size()) + " walls, play area " +
        std::to_string(sx) + " x " + std::to_string(sz) + " m" + (g_box.reseat ? ", centred on the box." : "."));
    return ok;
}

uint32_t LiveWallCount() {
    uint32_t n = 0;
    g_setup->GetLiveCollisionBoundsInfo(nullptr, &n);
    return n;
}

// The live chaperone walls as SteamVR holds them right now (empty if they cannot be read).
std::vector<vr::HmdQuad_t> LiveQuads() {
    uint32_t n = LiveWallCount();
    std::vector<vr::HmdQuad_t> quads(n);
    if (!n || !g_setup->GetLiveCollisionBoundsInfo(quads.data(), &n)) return {};
    quads.resize(std::min<size_t>(n, quads.size()));
    return quads;
}

bool SameQuads(const std::vector<vr::HmdQuad_t> &a, const std::vector<vr::HmdQuad_t> &b) {
    if (a.size() != b.size()) return false;
    for (size_t i = 0; i < a.size(); i++)
        for (int c = 0; c < 4; c++)
            for (int k = 0; k < 3; k++)
                if (std::fabs(a[i].vCorners[c].v[k] - b[i].vCorners[c].v[k]) > 0.001f) return false;
    return true;
}

// ---------- overlay walls ----------

struct Wall { vr::VROverlayHandle_t h = vr::k_ulOverlayHandleInvalid; P2 a{}, b{}; bool shown = false; float alpha = -1; };

std::vector<Wall> CreateWalls(const std::vector<P2> &poly, float base) {
    std::vector<Wall> walls;
    const int pxPerM = 32, texH = (int)(kWallHeight * pxPerM);
    for (size_t i = 0; i < poly.size(); i++) {
        Wall w; w.a = poly[i]; w.b = poly[(i + 1) % poly.size()];
        float len = Dist(w.a, w.b);
        if (len < 0.05f) continue;
        // Overlay +Z (its visible front) must face into the play space: X along the wall, Y up, Z = X cross Y.
        float dx = (w.b.x - w.a.x) / len, dz = (w.b.z - w.a.z) / len;
        P2 mid{(w.a.x + w.b.x) / 2, (w.a.z + w.b.z) / 2};
        if (!Inside(poly, {mid.x - dz * 0.05f, mid.z + dx * 0.05f})) { std::swap(w.a, w.b); dx = -dx; dz = -dz; }
        std::string key = "arcrift.boundary." + std::to_string(i);
        if (g_overlay->CreateOverlay(key.c_str(), ("ArcRift boundary " + std::to_string(i)).c_str(), &w.h) != vr::VROverlayError_None) {
            vr::VROverlayHandle_t old;
            if (g_overlay->FindOverlay(key.c_str(), &old) == vr::VROverlayError_None) g_overlay->DestroyOverlay(old);
            if (g_overlay->CreateOverlay(key.c_str(), ("ArcRift boundary " + std::to_string(i)).c_str(), &w.h) != vr::VROverlayError_None) {
                Log("Could not create overlay wall " + std::to_string(i));
                continue;
            }
        }
        int texW = std::max(4, (int)std::ceil(len * pxPerM));
        std::vector<uint8_t> px((size_t)texW * texH * 4);
        for (int y = 0; y < texH; y++) {
            for (int x = 0; x < texW; x++) {
                bool line = (x % 8 == 0) || (y % 8 == 0) || y < 2 || y >= texH - 2 || x == texW - 1;
                uint8_t *p = &px[((size_t)y * texW + x) * 4];
                p[0] = 40; p[1] = 200; p[2] = 255; p[3] = line ? 230 : 35;
            }
        }
        g_overlay->SetOverlayRaw(w.h, px.data(), texW, texH, 4);
        g_overlay->SetOverlayWidthInMeters(w.h, len);
        float height = len * texH / texW; // overlays keep the texture's aspect ratio
        vr::HmdMatrix34_t m{};
        m.m[0][0] = dx;  m.m[0][1] = 0; m.m[0][2] = -dz; m.m[0][3] = mid.x;
        m.m[1][0] = 0;   m.m[1][1] = 1; m.m[1][2] = 0;   m.m[1][3] = base + height / 2;
        m.m[2][0] = dz;  m.m[2][1] = 0; m.m[2][2] = dx;  m.m[2][3] = mid.z;
        g_overlay->SetOverlayTransformAbsolute(w.h, vr::TrackingUniverseStanding, &m);
        g_overlay->HideOverlay(w.h);
        walls.push_back(w);
    }
    return walls;
}

void UpdateWalls(std::vector<Wall> &walls, const std::vector<P2> &poly) {
    std::vector<P2> pts = TrackedPoints();
    if (pts.empty()) return;
    bool outside = !Inside(poly, pts[0]);
    for (Wall &w : walls) {
        float d = 1e9f;
        for (P2 p : pts) d = std::min(d, SegDist(p, w.a, w.b));
        float a = outside ? 1.0f : std::clamp((kFadeStart - d) / (kFadeStart - kFadeFull), 0.0f, 1.0f);
        if (a > 0.02f) {
            if (std::fabs(a - w.alpha) > 0.03f) { g_overlay->SetOverlayAlpha(w.h, a); w.alpha = a; }
            if (!w.shown) { g_overlay->ShowOverlay(w.h); w.shown = true; }
        } else if (w.shown) { g_overlay->HideOverlay(w.h); w.shown = false; }
    }
}

// ---------- saved outline ----------

// anchor: "controller" (start = where the trigger was first pulled and the way that controller pointed) or
// "headset" (1.2.1 first version: where the headset was when walking began and the way it faced).
// shape: "box <width> <depth>" for a quick box (start = its centre), empty for a traced outline.
bool SaveOutline(const std::vector<P2> &poly, P2 start, float yaw, const char *anchor, const std::string &shape = "") {
    std::ofstream f(RootFile(L"boundary-saved.txt"), std::ios::trunc);
    f << "# ArcRift room boundary. Tracking-space metres; start/anchor = the reference used to line it up again.\n";
    f << "anchor " << anchor << "\n";
    if (!shape.empty()) f << "shape " << shape << "\n";
    f.precision(4);
    f << std::fixed << "start " << start.x << " " << start.z << " " << yaw << "\n";
    for (P2 p : poly) f << "p " << p.x << " " << p.z << "\n";
    return (bool)f;
}

bool LoadOutline(std::vector<P2> &poly, P2 &start, float &yaw, std::string &anchor, std::string &shape, float &boxW, float &boxD) {
    std::ifstream f(RootFile(L"boundary-saved.txt"));
    std::string tag; bool haveStart = false;
    anchor = "headset";
    shape.clear();
    boxW = boxD = 0;
    while (f >> tag) {
        if (tag == "anchor") { f >> anchor; }
        else if (tag == "shape") {
            f >> shape; std::string rest; std::getline(f, rest);
            std::istringstream size(rest);
            if (!(size >> boxW >> boxD)) boxW = boxD = 0;
        }
        else if (tag == "start") { f >> start.x >> start.z >> yaw; haveStart = true; }
        else if (tag == "p") { P2 p; f >> p.x >> p.z; poly.push_back(p); }
        else { std::string rest; std::getline(f, rest); }
    }
    return haveStart && poly.size() >= 3;
}

// ---------- steps ----------

void Beep2(DWORD freq, DWORD ms) { Beep(freq, ms); }

// Countdown so you can get to the starting spot; returns false if stopped.
bool Countdown(const std::string &what, int seconds = kCountdownSeconds) {
    for (int s = seconds; s > 0; s--) {
        Status("countdown", what + " Starting in " + std::to_string(s) + " s.");
        if (s <= 3) Beep2(880, 150);
        for (int i = 0; i < 10; i++) { if (StopRequested()) return false; Sleep(s <= 3 ? 85 : 100); }
    }
    Beep2(1320, 400);
    return true;
}

bool WaitForTracking(P2 &pos, float &yaw) {
    for (int i = 0; i < 200; i++) {
        if (HmdPose(pos, yaw)) return true;
        if (StopRequested()) return false;
        if (i % 10 == 0) Status("countdown", "The headset is not tracking. Make sure its cameras can see the room (not covered, lights on).");
        Sleep(100);
    }
    return false;
}

// Keeps the boundary shown until SteamVR closes or another ArcRift boundary command takes over.
int Keep(std::vector<P2> poly) {
    BackupLiveChaperone();
    bool committed = CommitChaperone(poly);
    vr::ETrackedPropertyError pe = vr::TrackedProp_Success;
    bool driverVis = g_system->GetBoolTrackedDeviceProperty(vr::k_unTrackedDeviceIndex_Hmd, vr::Prop_DriverProvidedChaperoneVisibility_Bool, &pe);
    Log("Driver-provided chaperone visibility: " + std::string(pe == vr::TrackedProp_Success ? (driverVis ? "true" : "false") : "not set (error " + std::to_string((int)pe) + ")"));
    float wallBase = WallBase();
    std::vector<Wall> walls = CreateWalls(poly, wallBase);
    float area = Area(poly);
    std::string msg = "Boundary on: " + std::to_string(walls.size()) + " walls, about " + std::to_string((int)std::round(area)) +
        " m2. It fades in when you get close to an edge.";
    if (!committed) msg += " (SteamVR did not accept it for games; the walls still show.)";
    Status("active", msg, (int)poly.size(), 0, area, (int)walls.size());
    Log(msg);
    // What SteamVR holds right after our commit. Comparing wall counts alone cannot tell a quick box (4 walls) from
    // Meta's 1 x 1 m placeholder (also 4 walls), so the walls themselves are compared. If the snapshot is not ours
    // (commit refused, or it cannot be read back), fall back to the wall count.
    std::vector<vr::HmdQuad_t> ours = committed ? LiveQuads() : std::vector<vr::HmdQuad_t>();
    if (ours.size() != poly.size()) ours.clear();
    DWORD lastCheck = GetTickCount(), lastRecommit = 0;
    // Quick box as SteamVR's play area: where SteamVR's standing origin is now. Only compared with itself later, to
    // notice when something (Meta's driver, a recentre) moves the origin away from the box.
    vr::HmdMatrix34_t originSeen = g_system->GetRawZeroPoseToStandingAbsoluteTrackingPose();
    DWORD lastOriginCheck = GetTickCount(), lastOriginFix = 0;
    int exitCode = 0;
    for (;;) {
        if (StopRequested()) { Log("Stopped by another boundary command."); break; }
        vr::VREvent_t ev;
        bool quit = false, originEvent = false;
        while (g_system->PollNextEvent(&ev, sizeof(ev))) {
            if (ev.eventType == vr::VREvent_Quit) { g_system->AcknowledgeQuit_Exiting(); quit = true; }
            if (ev.eventType == vr::VREvent_ChaperoneUniverseHasChanged || ev.eventType == vr::VREvent_StandingZeroPoseReset) originEvent = true;
        }
        if (quit) { Status("off", "SteamVR closed. Next session, press \"Use saved boundary\" or make it again."); Log("SteamVR quit."); break; }
        if (g_box.active && (originEvent || GetTickCount() - lastOriginCheck > 1000) && GetTickCount() - lastOriginFix > 500) {
            lastOriginCheck = GetTickCount();
            if (!SamePose(g_system->GetRawZeroPoseToStandingAbsoluteTrackingPose(), originSeen, 0.03f, 0.026f)) {
                if (g_box.reseat && g_box.resets < 3) {
                    // Put the origin back on the box; the walls are drawn in that space, so they return with it.
                    g_box.resets++;
                    Log("SteamVR's play-area centre was moved; putting it back on the box (" + std::to_string(g_box.resets) + " of 3).");
                    CommitChaperone(poly);
                    for (int i = 0; i < 30 && !SamePose(g_system->GetRawZeroPoseToStandingAbsoluteTrackingPose(), originSeen, 0.03f, 0.026f); i++) Sleep(50);
                } else {
                    // It keeps being moved: stop fighting. Keep the box where it physically is, in SteamVR's own space.
                    g_box.reseat = false;
                    Sleep(300);
                    vr::HmdMatrix34_t s{};
                    if (LiveStandingToRaw(s)) {
                        poly = BoxCorners(Mul(Inverse(s), g_box.toRaw), g_box.w, g_box.d);
                        Log("SteamVR keeps its own play-area centre; the box stays where it is, but is no longer SteamVR's play area.");
                        committed = CommitChaperone(poly);
                        for (Wall &w : walls) g_overlay->DestroyOverlay(w.h);
                        walls = CreateWalls(poly, wallBase);
                        ours = committed ? LiveQuads() : std::vector<vr::HmdQuad_t>();
                        if (ours.size() != poly.size()) ours.clear();
                    } else Log("SteamVR's play-area centre moved and could not be read; the walls may be out of place. Press Box around me again.");
                    originSeen = g_system->GetRawZeroPoseToStandingAbsoluteTrackingPose();
                }
                lastOriginFix = GetTickCount();
            }
        }
        UpdateWalls(walls, poly);
        if (GetTickCount() - lastCheck > 3000) {
            lastCheck = GetTickCount();
            if (!ProcessId(L"vrserver.exe")) { Status("off", "SteamVR closed. Next session, press \"Use saved boundary\" or make it again."); Log("vrserver gone."); break; }
            // Meta's SteamVR driver can push its placeholder back; put ours back (at most every 10 s).
            bool replaced = ours.empty() ? LiveWallCount() != poly.size() : !SameQuads(LiveQuads(), ours);
            if (replaced && GetTickCount() - lastRecommit > 10000) {
                lastRecommit = GetTickCount();
                Log("SteamVR chaperone was replaced; applying the boundary again.");
                if (CommitChaperone(poly)) {
                    ours = LiveQuads();
                    if (ours.size() != poly.size()) ours.clear();
                }
            }
        }
        Sleep(30);
    }
    for (Wall &w : walls) g_overlay->DestroyOverlay(w.h);
    return exitCode;
}

// Shared end of drawing: simplify, check, save, show.
int FinishDrawing(const std::vector<P2> &path, float length, P2 start, float yaw, const char *anchor, const char *how) {
    Beep2(1320, 150); Sleep(80); Beep2(1320, 150);
    std::vector<P2> poly = Outline(path);
    float area = poly.size() >= 3 ? Area(poly) : 0;
    Log(std::string("Drawing finished (") + how + "): " + std::to_string(path.size()) + " points, " + std::to_string(length) +
        " m, outline " + std::to_string(poly.size()) + " walls, " + std::to_string(area) + " m2.");
    if (poly.size() < 3 || area < kMinArea) {
        Status("error", "That area was too small (under 1 m2). Trace a bigger loop around your play space and try again.", (int)path.size(), length, area);
        return 1;
    }
    SaveOutline(poly, start, yaw, anchor);
    return Keep(poly);
}

// Waits for a trigger press with a tracked controller; false on stop/timeout.
bool WaitForTrigger(const std::string &prompt, DWORD timeoutMs, uint32_t &device, P2 &pos, float &yaw) {
    DWORD began = GetTickCount(), lastStatus = 0;
    while (GetTickCount() - began < timeoutMs) {
        if (StopRequested()) return false;
        uint32_t d;
        if (TriggerDown(d) && d && DevicePose(d, pos, yaw)) { device = d; return true; }
        if (GetTickCount() - lastStatus > 1000) {
            lastStatus = GetTickCount();
            Status("waiting", DeviceSummary() ? prompt : prompt + "\n(No controller is tracked right now: wake one with a button press "
                                                                  "and hold it where the headset's cameras can see it.)");
        }
        Sleep(20);
    }
    std::string devices;
    DeviceSummary(&devices);
    Log("No trigger press seen. SteamVR Input " + std::string(g_inputReady ? "ready" : "not ready") + ". " + devices);
    return false;
}

const char *kNoTrigger = "No trigger press was detected. Make sure SteamVR shows both controllers, then try again, "
                         "or use \"Box around me\", which needs no controller. (boundary-log.txt has details.)";

// 1.2.1: trace the edge with a controller while holding its trigger. Wear the headset pushed up on your forehead:
// you see the room with your own eyes and its cameras still track the controller.
int DrawController() {
    TakeFinishRequest();
    uint32_t device = 0; P2 start; float yaw;
    { std::string devices; DeviceSummary(&devices); Log("Waiting for a trigger. " + devices); }
    if (!WaitForTrigger("Wear the headset pushed up on your forehead, cameras facing forward. At the edge of your play space, "
                        "hold the TRIGGER on a controller to start, and keep holding it while you trace the edge.",
                        3 * 60 * 1000, device, start, yaw)) {
        if (StopRequested()) { Status("cancelled", "Boundary drawing cancelled."); return 1; }
        Status("error", kNoTrigger);
        return 1;
    }
    Beep2(1320, 200);
    Buzz(device, 0.15f, 0.8f);
    std::vector<P2> path{start};
    float length = 0;
    DWORD began = GetTickCount(), lost = 0, lastStatus = 0;
    bool held = true;
    const char *how = "loop closed";
    Log("Controller drawing started on device " + std::to_string(device) + ".");
    for (;;) {
        if (StopRequested()) { Status("cancelled", "Boundary drawing cancelled."); return 1; }
        if (TakeFinishRequest()) { how = "Finish now"; break; }
        DWORD now = GetTickCount();
        if (now - began > kDrawTimeoutMs) { how = "time limit"; break; }
        uint32_t d;
        bool down = TriggerDown(d);
        if (down && d) device = d;
        if (down) {
            held = true;
            P2 p; float y;
            if (DevicePose(device, p, y)) {
                lost = 0;
                float step = Dist(p, path.back());
                if (step >= kSampleStep) { path.push_back(p); length += step; Buzz(device, 0.01f, 0.35f); }
                if (length >= kMinLoopLength && Dist(p, start) <= 0.35f && now - began > 5000) break;
            } else if (!lost) lost = now;
        } else if (held) {
            held = false;
            if (length >= kMinLoopLength) { how = "trigger released"; break; } // all the way round: done
        }
        if (now - lastStatus > 500) {
            lastStatus = now;
            if (!held) Status("recording", "Paused: hold the trigger again to keep tracing.", (int)path.size(), length);
            else if (lost && now - lost > 2000) Status("recording", "The controller is not tracked: keep it in front of the headset's cameras.", (int)path.size(), length);
            else Status("recording", "Recording: keep the trigger held and trace the edge of your play space. Come back to where you started to finish.", (int)path.size(), length);
        }
        Sleep(20);
    }
    Buzz(device, 0.4f, 1.0f);
    return FinishDrawing(path, length, start, yaw, "controller", how);
}

// First 1.2.1 method, kept as "drawwalk": walk the edge holding the headset.
int DrawWalk() {
    if (!Countdown("Stand at the edge of your play space holding the headset in front of you at chest height, cameras facing forward.")) {
        Status("cancelled", "Boundary drawing cancelled.");
        return 1;
    }
    P2 start; float yaw;
    if (!WaitForTracking(start, yaw)) {
        Status("error", "The headset was not tracking, so nothing was drawn. Keep its cameras facing the room and try again.");
        return 1;
    }
    TakeFinishRequest();
    std::vector<P2> path{start};
    float length = 0;
    DWORD began = GetTickCount(), lost = 0, lastStatus = 0;
    bool finish = false;
    Log("Drawing started.");
    for (;;) {
        if (StopRequested()) { Status("cancelled", "Boundary drawing cancelled."); return 1; }
        if (TakeFinishRequest()) { finish = true; break; }
        DWORD now = GetTickCount();
        if (now - began > kDrawTimeoutMs) { finish = true; break; }
        P2 p; float y;
        if (HmdPose(p, y)) {
            lost = 0;
            float d = Dist(p, path.back());
            if (d >= kSampleStep) { path.push_back(p); length += d; }
            if (length >= kMinLoopLength && Dist(p, start) <= kCloseDistance && now - began > 8000) break;
        } else if (!lost) lost = now;
        if (now - lastStatus > 500) {
            lastStatus = now;
            if (lost && now - lost > 2000) Status("recording", "Tracking lost: keep the headset's cameras facing the room and walk slowly.", (int)path.size(), length);
            else Status("recording", "Recording: walk slowly along the edge of your free space, then come back to where you started.", (int)path.size(), length);
        }
        Sleep(50);
    }
    return FinishDrawing(path, length, start, yaw, "headset", finish ? "by request/timeout" : "loop closed");
}

// Places a width x depth box around the headset pose (c, yaw) and keeps it shown. 1.3: first tries to make the box
// SteamVR's play area by moving SteamVR's standing origin to the box centre (see BoxAnchor). That is only kept if the
// headset then really reads as standing in the middle of the box facing forward; otherwise the origin is put back and
// the box is placed the old way (walls correct, SteamVR play area = the part of the box that fits around its origin).
int PlaceBox(P2 c, float yaw, float width, float depth) {
    std::vector<P2> poly = BoxOutline(c, yaw, width, depth);
    P2 start = c;
    float startYaw = yaw;
    char buf[240];
    vr::HmdMatrix34_t before{};
    if (LiveStandingToRaw(before)) {
        BackupLiveChaperone();
        BackupStandingOrigin(before);
        g_box.w = width; g_box.d = depth;
        g_box.toRaw = Mul(before, BoxFrame(c, yaw));
        g_box.reseat = true;
        std::vector<P2> centred = BoxOutline({0, 0}, kPi, width, depth);
        if (CommitChaperone(centred) && WaitHeadsetAt({0, 0}, kPi, 1500)) {
            g_box.active = true;
            poly = centred; start = {0, 0}; startYaw = kPi;
            sprintf_s(buf, "SteamVR play area is now the box: %.2f x %.2f m, centred where you stood and facing the way you faced.", width, depth);
            Log(buf);
        } else {
            g_box.reseat = false;
            g_setup->RevertWorkingCopy();
            g_setup->SetWorkingStandingZeroPoseToRawTrackingPose(&before);
            g_setup->CommitWorkingCopy(vr::EChaperoneConfigFile_Live);
            bool back = WaitHeadsetAt(c, yaw, 1500);
            Log(std::string("SteamVR did not take the box as its play-area centre; placing the box the old way") +
                (back ? "." : " (the headset moved meanwhile, or SteamVR is still settling: check the walls, and press Box around me again if they look out of place)."));
        }
    } else Log("SteamVR's standing origin could not be read; placing the box the old way.");
    Beep2(1320, 150); Sleep(80); Beep2(1320, 150);
    sprintf_s(buf, "Box %.3g x %.3g m placed around (%.2f, %.2f), facing %.0f deg.", width, depth, c.x, c.z, yaw * 57.2958f);
    Log(buf);
    char shape[64];
    sprintf_s(shape, "box %.2f %.2f", width, depth);
    SaveOutline(poly, start, startYaw, "headset", shape);
    return Keep(poly);
}

// Quick box: after a countdown, a width x depth rectangle around the headset, lined up with the way it faces.
// Needs no controller input, so it works even when a trigger press does not reach this helper.
int Box(float width, float depth) {
    char size[64];
    sprintf_s(size, "%.3g x %.3g m", width, depth);
    if (!Countdown(std::string("Put the headset on, stand in the middle of your play space and face forward. A ") + size +
                   " box is placed around you.", kBoxCountdownSeconds)) {
        Status("cancelled", "Boundary cancelled.");
        return 1;
    }
    P2 c; float yaw;
    if (!WaitForTracking(c, yaw)) {
        if (StopRequested()) { Status("cancelled", "Boundary cancelled."); return 1; }
        std::string devices;
        DeviceSummary(&devices);
        Log("Box: headset not tracking. " + devices);
        Status("error", "The headset was not tracking, so no box was placed. Put it on (or hold it up) with its cameras facing the room and try again.");
        return 1;
    }
    return PlaceBox(c, yaw, width, depth);
}

int Apply() {
    std::vector<P2> saved; P2 s0; float yaw0, boxW, boxD; std::string anchor, shape;
    if (!LoadOutline(saved, s0, yaw0, anchor, shape, boxW, boxD)) { Status("error", "There is no saved boundary yet. Use \"Box around me\" or \"Draw boundary\" first."); return 1; }
    P2 s1; float yaw1;
    if (anchor == "controller") {
        uint32_t device = 0;
        if (!WaitForTrigger("Hold a controller on the spot where you started drawing, pointing the same way as when you started, "
                            "then pull the trigger.", 2 * 60 * 1000, device, s1, yaw1)) {
            if (StopRequested()) { Status("cancelled", "Cancelled."); return 1; }
            Status("error", kNoTrigger);
            return 1;
        }
        Buzz(device, 0.3f, 1.0f);
    } else {
        if (!Countdown(shape == "box" ? "Put the headset on, stand in the middle of your play space and face the same way as when you made the box."
                                      : "Stand on the spot where you started drawing, facing the same way, holding the headset the same way.")) {
            Status("cancelled", "Cancelled.");
            return 1;
        }
        if (!WaitForTracking(s1, yaw1)) { Status("error", "The headset was not tracking. Keep its cameras facing the room and try again."); return 1; }
        // A saved box is simply a box of that size around where you stand now, so it also becomes SteamVR's play area.
        if (shape == "box" && boxW >= kBoxMin && boxW <= kBoxMax && boxD >= kBoxMin && boxD <= kBoxMax) {
            Log("Saved box placed again around the headset.");
            return PlaceBox(s1, yaw1, boxW, boxD);
        }
    }
    float a = yaw1 - yaw0, c = std::cos(a), s = std::sin(a);
    std::vector<P2> poly;
    for (P2 p : saved) {
        float vx = p.x - s0.x, vz = p.z - s0.z;
        poly.push_back({s1.x + vx * c + vz * s, s1.z - vx * s + vz * c});
    }
    Beep2(1320, 150); Sleep(80); Beep2(1320, 150);
    Log("Saved boundary aligned: moved " + std::to_string(Dist(s0, s1)) + " m, turned " + std::to_string(a * 57.2958f) + " deg.");
    return Keep(poly);
}

int Clear() {
    if (!ProcessId(L"vrserver.exe")) { Status("cleared", "Boundary removed."); return 0; }
    std::string err;
    if (!InitVR(vr::VRApplication_Background, err)) { Status("error", err); return 1; }
    std::wstring path = RootFile(L"boundary-chaperone-backup.txt");
    std::ifstream f(path, std::ios::binary);
    DWORD pid = 0;
    bool restored = false;
    if (f >> pid && pid == ProcessId(L"vrserver.exe")) {
        std::string rest((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
        size_t b = rest.find('{');
        if (b != std::string::npos && g_setup->ImportFromBufferToWorking(rest.c_str() + b, 0)) {
            restored = g_setup->CommitWorkingCopy(vr::EChaperoneConfigFile_Live);
        }
    }
    if (!restored) g_setup->ReloadFromDisk(vr::EChaperoneConfigFile_Live);
    // 1.3: a quick box moved SteamVR's standing origin; put that back as well.
    {
        std::ifstream o(RootFile(L"boundary-origin-backup.txt"));
        DWORD opid = 0;
        vr::HmdMatrix34_t origin{};
        bool have = (bool)(o >> opid) && opid == ProcessId(L"vrserver.exe");
        for (int i = 0; have && i < 3; i++) for (int j = 0; j < 4; j++) if (!(o >> origin.m[i][j])) have = false;
        if (have) {
            g_setup->RevertWorkingCopy();
            g_setup->SetWorkingStandingZeroPoseToRawTrackingPose(&origin);
            bool ok = g_setup->CommitWorkingCopy(vr::EChaperoneConfigFile_Live);
            Log(std::string("SteamVR's play-area centre put back where it was before the box") + (ok ? "." : ": FAILED."));
        }
    }
    Log(std::string("Boundary removed; chaperone ") + (restored ? "restored from backup." : "reloaded from SteamVR."));
    Status("cleared", "Boundary removed.");
    g_shutdown();
    return 0;
}

// Offline check of the outline/geometry maths (no SteamVR needed): arcrift_boundary.exe selftest
int SelfTest() {
    int fails = 0;
    auto check = [&](bool ok, const char *what) { printf("%s %s\n", ok ? "ok  " : "FAIL", what); if (!ok) fails++; };
    // A 3 x 2 m rectangle walked with 2 cm of wobble, centred on the origin, back to the start.
    std::vector<P2> path;
    unsigned seed = 1;
    auto wob = [&]() { seed = seed * 1103515245u + 12345u; return ((int)((seed >> 16) % 2001) - 1000) / 50000.0f; };
    P2 corners[5] = {{-1.5f, -1}, {1.5f, -1}, {1.5f, 1}, {-1.5f, 1}, {-1.5f, -1}};
    for (int c = 0; c < 4; c++)
        for (int i = 0; i < 30; i++) {
            float t = i / 30.0f;
            path.push_back({corners[c].x + (corners[c + 1].x - corners[c].x) * t + wob(), corners[c].z + (corners[c + 1].z - corners[c].z) * t + wob()});
        }
    std::vector<P2> poly = Outline(path);
    float area = Area(poly);
    printf("     outline: %zu walls, %.2f m2\n", poly.size(), area);
    check(poly.size() >= 4 && poly.size() <= 8, "rectangle simplifies to a few walls");
    check(std::fabs(area - 6.0f) < 0.4f, "area is about 6 m2");
    check(Inside(poly, {0, 0}) && !Inside(poly, {2, 0}), "inside/outside test");
    float sx, sz;
    PlayArea(poly, sx, sz);
    printf("     play area: %.2f x %.2f m\n", sx, sz);
    check(sx > 2.4f && sx <= 3.05f && sz > 1.6f && sz <= 2.05f, "play area fits the rectangle");
    // Same room, but this session's tracking origin is moved 1 m and turned 90 degrees: aligning on the start
    // point and heading must give the same physical outline.
    P2 s0 = path[0]; float yaw0 = 0.3f, rot = 1.5708f;
    auto toNew = [&](P2 p) { float c = std::cos(rot), s = std::sin(rot); return P2{1 + p.x * c + p.z * s, -p.x * s + p.z * c}; };
    P2 s1 = toNew(s0); float yaw1 = yaw0 + rot;
    float a = yaw1 - yaw0, c = std::cos(a), s = std::sin(a);
    float worst = 0;
    for (P2 p : poly) {
        float vx = p.x - s0.x, vz = p.z - s0.z;
        P2 q{s1.x + vx * c + vz * s, s1.z - vx * s + vz * c};
        worst = std::max(worst, Dist(q, toNew(p)));
    }
    check(worst < 0.001f, "saved boundary re-aligns after the origin moved and turned");
    PlayArea({{1, 1}, {3, 1}, {3, 3}, {1, 3}}, sx, sz);
    check(sx == 0 && sz == 0, "no play area when the origin is outside the outline");
    // Quick box: 2 m wide, 3 m deep, around (1, 2), headset turned 30 degrees.
    P2 bc{1, 2}; float byaw = 0.5236f;
    std::vector<P2> box = BoxOutline(bc, byaw, 2, 3);
    P2 fwd{std::sin(byaw), std::cos(byaw)};
    P2 front{(box[2].x + box[3].x) / 2, (box[2].z + box[3].z) / 2};
    check(box.size() == 4 && std::fabs(Area(box) - 6.0f) < 0.001f, "box has 4 walls and the right area");
    check(std::fabs(Dist(box[0], box[1]) - 2) < 0.001f && std::fabs(Dist(box[1], box[2]) - 3) < 0.001f, "box is width x depth");
    check(Inside(box, bc) && Dist(front, {bc.x + fwd.x * 1.5f, bc.z + fwd.z * 1.5f}) < 0.001f, "box is centred on the headset, depth along its facing");
    PlayArea(BoxOutline({0, 0}, 0, 2, 3), sx, sz);
    printf("     box play area: %.2f x %.2f m\n", sx, sz);
    check(sx > 1.8f && sx <= 2.0f && sz > 2.7f && sz <= 3.0f, "box around the origin gives SteamVR its play area");
    // 1.3: quick box as SteamVR's play area. SteamVR's standing origin sits somewhere in raw tracking space; the
    // headset stands at (0.5, -0.3) in standing space, facing 2 rad. Moving the origin to the box must leave the
    // headset in the middle of the box facing forward (-Z, heading pi), at the same height.
    vr::HmdMatrix34_t standing = BoxFrame({1.0f, -2.0f}, 0.7f);
    standing.m[1][3] = 0.2f;
    P2 hc{0.5f, -0.3f}; float hyaw = 2.0f;
    vr::HmdMatrix34_t head = BoxFrame(hc, hyaw); // a headset pose has the same form
    head.m[1][3] = 1.7f;
    vr::HmdMatrix34_t toRaw = Mul(standing, BoxFrame(hc, hyaw));
    vr::HmdMatrix34_t headAfter = Mul(Inverse(toRaw), Mul(standing, head));
    check(SamePose(Mul(standing, Inverse(standing)), BoxFrame({0, 0}, kPi), 0.001f, 0.001f), "matrix inverse");
    check(std::fabs(AngleDiff(MatrixYaw(BoxFrame(hc, hyaw)), hyaw)) < 0.001f, "box space faces the way the headset faced");
    check(std::hypot(headAfter.m[0][3], headAfter.m[2][3]) < 0.001f && std::fabs(headAfter.m[1][3] - 1.7f) < 0.001f &&
          std::fabs(AngleDiff(MatrixYaw(headAfter), kPi)) < 0.001f, "moving the standing origin puts the headset in the middle of the box, facing forward");
    std::vector<P2> oldWay = BoxOutline(hc, hyaw, 2, 3), viaRaw = BoxCorners(Mul(Inverse(standing), toRaw), 2, 3);
    std::vector<P2> centred = BoxOutline({0, 0}, kPi, 2, 3), centredViaRaw = BoxCorners(Mul(Inverse(toRaw), toRaw), 2, 3);
    worst = 0;
    for (size_t i = 0; i < 4; i++) worst = std::max({worst, Dist(oldWay[i], viaRaw[i]), Dist(centred[i], centredViaRaw[i])});
    check(worst < 0.001f, "the box is the same physical box in the old and the moved standing space");
    bool axis = true;
    for (P2 p : centred) if (std::fabs(std::fabs(p.x) - 1.0f) > 0.001f || std::fabs(std::fabs(p.z) - 1.5f) > 0.001f) axis = false;
    check(axis, "in the moved space the box is exactly the width x depth play area around the origin");
    printf(fails ? "SELFTEST FAILED\n" : "SELFTEST OK\n");
    return fails ? 1 : 0;
}

} // namespace

int wmain(int argc, wchar_t **argv) {
    wchar_t exe[MAX_PATH];
    GetModuleFileNameW(nullptr, exe, MAX_PATH);
    g_root = exe;
    g_root = g_root.substr(0, g_root.find_last_of(L'\\'));
    std::wstring cmd = argc > 1 ? argv[1] : L"";
    if (cmd == L"selftest") return SelfTest();
    if (cmd == L"finish") {
        std::ofstream(RootFile(L"boundary-finish.txt")) << "finish\n";
        return 0;
    }
    if (cmd != L"box" && cmd != L"draw" && cmd != L"drawwalk" && cmd != L"apply" && cmd != L"clear") {
        fprintf(stderr, "usage: arcrift_boundary.exe box [width] [depth]|draw|drawwalk|apply|clear|finish|selftest\n");
        return 2;
    }
    float boxW = 2.0f, boxD = 2.0f;
    if (cmd == L"box") {
        if (argc > 2) boxW = boxD = (float)_wtof(argv[2]);
        if (argc > 3) boxD = (float)_wtof(argv[3]);
        if (!(boxW >= kBoxMin && boxW <= kBoxMax && boxD >= kBoxMin && boxD <= kBoxMax)) {
            fprintf(stderr, "box: width and depth must be between %.0f and %.0f m\n", kBoxMin, kBoxMax);
            return 2;
        }
    }
    // One boundary helper at a time: a new command stops the running one, then takes over.
    g_stopEvent = CreateEventW(nullptr, TRUE, FALSE, L"Local\\ArcRiftBoundaryStop");
    HANDLE mutex = CreateMutexW(nullptr, FALSE, L"Local\\ArcRiftBoundaryRun");
    DWORD w = WaitForSingleObject(mutex, 0);
    if (w == WAIT_TIMEOUT) { SetEvent(g_stopEvent); w = WaitForSingleObject(mutex, 8000); }
    if (w != WAIT_OBJECT_0 && w != WAIT_ABANDONED) { Status("error", "Another boundary helper did not stop. Try again."); return 1; }
    ResetEvent(g_stopEvent);
    Log("Command: " + Narrow(cmd));
    int rc;
    if (cmd == L"clear") {
        rc = Clear();
    } else {
        if (!ProcessId(L"vrserver.exe")) { Status("error", "SteamVR is not running. Start a VR session first."); return 1; }
        std::string err;
        if (!InitVR(vr::VRApplication_Overlay, err)) { Status("error", err); Log(err); return 1; }
        InitInput();
        rc = cmd == L"box" ? Box(boxW, boxD) : cmd == L"draw" ? DrawController() : cmd == L"drawwalk" ? DrawWalk() : Apply();
        g_shutdown();
    }
    ReleaseMutex(mutex);
    return rc;
}
