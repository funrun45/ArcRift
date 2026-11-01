// ArcRift Control: a small launcher/status app for the ArcRiftLab Rift S + Intel Arc bridge.
// It never touches the display/runtime itself: it runs the folder's own, tested PowerShell scripts
// (start-vrchat-trial.ps1 -ManualSession, stop-arc-rift.ps1, recover-manual-session.ps1) and reads
// their status files. The UI is a local web page shown in an Edge app window.
package main

import (
	"crypto/rand"
	"embed"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io/fs"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
	"unsafe"
)

//go:embed web
var webFiles embed.FS

const appVersion = "1.1.1"

var (
	root      string
	token     string
	lastHit   = time.Now()
	lastHitMu sync.Mutex

	wrapperMu   sync.Mutex
	wrapperProc *os.Process
	wrapperDone = true

	cacheMu       sync.Mutex
	headsetCache  = map[string]any{"checked": false}
	serviceCache  = "unknown"
	slowUpdatedAt time.Time

	setupMu    sync.Mutex
	setupSnaps = map[int][]pnpDevice{}
	setupGPU   []gpuInfo
)

const createNoWindow = 0x08000000

func hidden(cmd *exec.Cmd) *exec.Cmd {
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: createNoWindow}
	return cmd
}

func psFile(script string, args ...string) *exec.Cmd {
	a := append([]string{"-NoProfile", "-ExecutionPolicy", "Bypass", "-File", filepath.Join(root, script)}, args...)
	cmd := exec.Command("powershell.exe", a...)
	cmd.Dir = root
	return hidden(cmd)
}

func psCommand(command string) *exec.Cmd {
	return hidden(exec.Command("powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", command))
}

// ---------- processes ----------

func processList() map[string][]uint32 {
	out := map[string][]uint32{}
	snap, err := syscall.CreateToolhelp32Snapshot(syscall.TH32CS_SNAPPROCESS, 0)
	if err != nil {
		return out
	}
	defer syscall.CloseHandle(snap)
	var e syscall.ProcessEntry32
	e.Size = uint32(unsafe.Sizeof(e))
	if syscall.Process32First(snap, &e) != nil {
		return out
	}
	for {
		name := strings.ToLower(syscall.UTF16ToString(e.ExeFile[:]))
		out[name] = append(out[name], e.ProcessID)
		if syscall.Process32Next(snap, &e) != nil {
			break
		}
	}
	return out
}

func pidAlive(procs map[string][]uint32, pid int) bool {
	for _, pids := range procs {
		for _, p := range pids {
			if int(p) == pid {
				return true
			}
		}
	}
	return false
}

// ---------- session files ----------

var (
	reSessionDir = regexp.MustCompile(`<S N="SessionDirectory">([^<]*)</S>`)
	reHarnessPid = regexp.MustCompile(`<I32 N="HarnessPid">(\d+)</I32>`)
	reCleanup    = regexp.MustCompile(`"CleanupVerified":\s*(true|false)`)
)

func xmlUnescape(s string) string {
	r := strings.NewReplacer("&amp;", "&", "&lt;", "<", "&gt;", ">", "&quot;", "\"", "&apos;", "'")
	return r.Replace(s)
}

func readText(path string, max int64) string {
	f, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer f.Close()
	st, _ := f.Stat()
	if st != nil && max > 0 && st.Size() > max {
		f.Seek(st.Size()-max, 0)
	}
	b := make([]byte, max)
	if max <= 0 {
		b, _ = os.ReadFile(path)
		return decodeText(b)
	}
	n, _ := f.Read(b)
	return decodeText(b[:n])
}

func decodeText(b []byte) string {
	if len(b) >= 2 && b[0] == 0xFF && b[1] == 0xFE { // UTF-16 LE
		u := make([]uint16, 0, len(b)/2)
		for i := 2; i+1 < len(b); i += 2 {
			u = append(u, uint16(b[i])|uint16(b[i+1])<<8)
		}
		return syscall.UTF16ToString(u)
	}
	s := strings.TrimPrefix(string(b), "\ufeff")
	return strings.ReplaceAll(s, "\x00", "")
}

func latestSessionDir() string {
	m, _ := filepath.Glob(filepath.Join(root, "d3d11-*"))
	sort.Strings(m)
	for i := len(m) - 1; i >= 0; i-- {
		if st, err := os.Stat(m[i]); err == nil && st.IsDir() {
			return m[i]
		}
	}
	return ""
}

var headerLine = regexp.MustCompile(`^(\*+|Windows PowerShell transcript|Start time:|End time:|Username:|RunAs User:|Configuration Name:|Machine:|Host Application:|Process ID:|PS[A-Za-z]*:|BuildVersion:|CLRVersion:|WSManStackVersion:|SerializationVersion:|Transcript started|Microsoft PnP Utility|\s*$)`)

func logTail(dir string, n int) []string {
	if dir == "" {
		return nil
	}
	text := readText(filepath.Join(dir, "transcript.txt"), 64*1024)
	var lines []string
	for _, l := range strings.Split(strings.ReplaceAll(text, "\r", ""), "\n") {
		if headerLine.MatchString(l) {
			continue
		}
		lines = append(lines, l)
	}
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	return lines
}

func sessionResult(dir string) (string, string) {
	t := readText(filepath.Join(dir, "transcript.txt"), 256*1024)
	reason := ""
	if m := regexp.MustCompile(`TEST STOP: ([^\r\n]+)`).FindStringSubmatch(t); m != nil {
		reason = m[1]
	} else if strings.Contains(t, "User requested early stop") {
		reason = "Stopped by you"
	}
	recov, _ := filepath.Glob(filepath.Join(dir, "manual-recovery-2*.txt"))
	for _, r := range recov {
		if strings.Contains(readText(r, 0), "RECOVERY VERIFIED") {
			return "recovered", reason
		}
	}
	if strings.Contains(t, "ROLLBACK VERIFIED") {
		return "restored", reason
	}
	st := readText(filepath.Join(dir, "manual-recovery-state.json"), 0)
	if m := reCleanup.FindStringSubmatch(st); m != nil && m[1] == "true" {
		return "restored", reason
	}
	return "unknown", reason
}

type hiccupSummary struct {
	Hitches    int    `json:"hitches"`
	HeadsetOff bool   `json:"headsetOff"`
	LowFps     int    `json:"lowFps"`
	Last       string `json:"last"`
}

func hiccups(dir string) hiccupSummary {
	var h hiccupSummary
	t := readText(filepath.Join(dir, "sync-hiccups.txt"), 512*1024)
	for _, l := range strings.Split(t, "\n") {
		switch {
		case strings.Contains(l, "AcquireSync FAILED"):
			h.Hitches++
		case strings.Contains(l, "headset off"):
			h.HeadsetOff = true
			h.Last = strings.TrimSpace(l)
		case strings.Contains(l, "headset on") || strings.Contains(l, "frames flowing"):
			h.HeadsetOff = false
			h.Last = strings.TrimSpace(l)
		case strings.Contains(l, "fps (low sample"):
			h.LowFps++
		}
	}
	return h
}

var reSceneApp = regexp.MustCompile(`New Connect message from (.+?\.exe) \(VRApplication_Scene\)`)

// currentGame returns the VR game SteamVR last saw connect as a scene app, if that program is still running.
func currentGame(procs map[string][]uint32) string {
	if len(procs["vrserver.exe"]) == 0 {
		return ""
	}
	log := filepath.Join(os.Getenv("ProgramFiles(x86)"), `Steam\logs\vrserver.txt`)
	m := reSceneApp.FindAllStringSubmatch(readText(log, 512*1024), -1)
	if len(m) == 0 {
		return ""
	}
	exe := filepath.Base(strings.ReplaceAll(m[len(m)-1][1], "/", `\`))
	if len(procs[strings.ToLower(exe)]) == 0 {
		return ""
	}
	return strings.TrimSuffix(exe, filepath.Ext(exe))
}

// ---------- slow checks (service, headset presence) ----------

type identity struct {
	MonitorInstance string `json:"monitorInstance"`
	TargetID        int    `json:"targetId"`
	GPUName         string `json:"gpuName"`
	GPUPnpMatch     string `json:"gpuPnpMatch"`
	HeadsetModel    string `json:"headsetModel"`
	HeadsetSerial   string `json:"headsetSerial"`
	SerialSource    string `json:"serialSource,omitempty"`
}

func savedConfig() (*identity, string) {
	p := filepath.Join(root, "arcrift-config.json")
	b, err := os.ReadFile(p)
	if err != nil {
		return nil, ""
	}
	var id identity
	if json.Unmarshal(b, &id) != nil {
		return nil, ""
	}
	st, _ := os.Stat(p)
	return &id, st.ModTime().Format("2006-01-02 15:04")
}

func refreshSlow() {
	cacheMu.Lock()
	if time.Since(slowUpdatedAt) < 5*time.Second {
		cacheMu.Unlock()
		return
	}
	slowUpdatedAt = time.Now()
	cacheMu.Unlock()
	svc := "unknown"
	if out, err := hidden(exec.Command("sc.exe", "query", "OVRService")).Output(); err == nil || len(out) > 0 {
		s := string(out)
		switch {
		case strings.Contains(s, "RUNNING"):
			svc = "running"
		case strings.Contains(s, "STOPPED"):
			svc = "stopped"
		case strings.Contains(s, "PENDING"):
			svc = "changing"
		case strings.Contains(s, "1060"):
			svc = "not installed"
		}
	}
	var id identity
	if cfg, _ := savedConfig(); cfg != nil {
		id = *cfg
	}
	hs := map[string]any{"checked": true, "present": false, "instance": id.MonitorInstance}
	if id.MonitorInstance != "" {
		out, _ := hidden(exec.Command("pnputil.exe", "/enum-devices", "/instanceid", id.MonitorInstance, "/connected")).Output()
		hs["present"] = strings.Contains(strings.ToLower(string(out)), strings.ToLower(id.MonitorInstance))
	}
	cacheMu.Lock()
	serviceCache = svc
	headsetCache = hs
	cacheMu.Unlock()
}

// ---------- status ----------

func status() map[string]any {
	go refreshSlow()
	procs := processList()
	has := func(n string) bool { return len(procs[strings.ToLower(n)]) > 0 }
	s := map[string]any{"version": appVersion, "root": root}

	marker := readText(filepath.Join(root, "active-test.xml"), 0)
	state := "idle"
	sessionDir := ""
	harnessAlive := false
	if marker != "" {
		if m := reSessionDir.FindStringSubmatch(marker); m != nil {
			sessionDir = xmlUnescape(m[1])
		}
		pid := 0
		if m := reHarnessPid.FindStringSubmatch(marker); m != nil {
			pid, _ = strconv.Atoi(m[1])
		}
		harnessAlive = pid > 0 && pidAlive(procs, pid)
		cleaned := false
		if m := reCleanup.FindStringSubmatch(readText(filepath.Join(sessionDir, "manual-recovery-state.json"), 0)); m != nil {
			cleaned = m[1] == "true"
		}
		switch {
		case harnessAlive && fileExists(filepath.Join(sessionDir, "session-stop.txt")):
			state = "stopping"
		case harnessAlive && strings.Contains(readText(filepath.Join(sessionDir, "transcript.txt"), 256*1024), "TEST STOP"):
			state = "stopping"
		case harnessAlive && fileExists(filepath.Join(sessionDir, "session-ready.txt")):
			state = "running"
		case harnessAlive:
			state = "starting"
		case cleaned:
			state = "idle"
		default:
			state = "recovery"
		}
	} else {
		wrapperMu.Lock()
		if !wrapperDone {
			state = "starting"
		}
		wrapperMu.Unlock()
	}
	logDir := sessionDir
	if logDir == "" {
		logDir = latestSessionDir()
	}
	s["state"] = state
	s["sessionDir"] = sessionDir
	s["logDir"] = logDir
	s["log"] = logTail(logDir, 60)
	if logDir != "" {
		s["hiccups"] = hiccups(logDir)
		if st, err := os.Stat(filepath.Join(logDir, "vrchat-trial-timing.json")); err == nil {
			s["sessionStarted"] = st.ModTime().Format(time.RFC3339)
		}
		res, reason := sessionResult(logDir)
		s["lastResult"] = res
		s["lastReason"] = reason
		s["lastName"] = filepath.Base(logDir)
	}
	game := currentGame(procs)
	s["gameName"] = game
	s["processes"] = map[string]bool{
		"harness":    harnessAlive,
		"meta":       has("OVRServer_x64.exe"),
		"steamvr":    has("vrserver.exe"),
		"compositor": has("vrcompositor.exe"),
		"game":       game != "",
		"debugTool":  has("OculusDebugTool.exe"),
		"presentmon": has("PresentMon.exe"),
	}
	cacheMu.Lock()
	s["service"] = serviceCache
	s["headset"] = headsetCache
	cacheMu.Unlock()
	cfg, when := savedConfig()
	if cfg != nil {
		s["config"] = cfg
		s["configSaved"] = when
		s["compatible"] = compatible(*cfg)
	}
	missing := []string{}
	for _, f := range releasePrograms {
		if !fileExists(filepath.Join(root, f)) {
			missing = append(missing, f)
		}
	}
	if !fileExists(filepath.Join(root, "release-manifest.json")) {
		missing = append(missing, "release-manifest.json")
	}
	s["missingPrograms"] = missing
	s["presentmonAvailable"] = fileExists(filepath.Join(root, "PresentMon.exe"))
	return s
}

var releasePrograms = []string{"arc_rift_bridge.dll", "native_source_test.exe", "native_source_session.exe", "display_probe.exe", "bridge_selftest.exe"}

// GPUs a full VRChat session has been confirmed on. Other Intel GPUs are allowed but marked untested.
var testedGPUs = map[string]string{"VEN_8086&DEV_56A0": "Intel Arc A770"}

func compatible(c identity) map[string]any {
	issues, warnings := []string{}, []string{}
	if c.MonitorInstance == "" || c.TargetID <= 0 {
		issues = append(issues, "no headset display recorded; run Setup again")
	}
	if !reSerial.MatchString(c.HeadsetSerial) {
		issues = append(issues, "headset serial number not found; open the Meta Horizon app with the headset connected and run Setup again")
	}
	gpu := strings.ToUpper(c.GPUPnpMatch)
	switch {
	case gpu == "":
		issues = append(issues, "no GPU recorded; run Setup again")
	case !strings.HasPrefix(gpu, "VEN_8086&"):
		issues = append(issues, "the GPU is not an Intel GPU ("+c.GPUName+"); this project only supports Intel Arc")
	case testedGPUs[gpu] == "":
		warnings = append(warnings, c.GPUName+" has not been tested yet. It may work; all safety guards and automatic restore stay active")
	}
	return map[string]any{"ok": len(issues) == 0, "issues": issues, "warnings": warnings, "tested": testedGPUs[gpu] != ""}
}

func fileExists(p string) bool {
	_, err := os.Stat(p)
	return err == nil
}

// ---------- actions ----------

func startSession() (string, error) {
	st := status()
	if st["state"] != "idle" {
		return "", fmt.Errorf("a session is already %v", st["state"])
	}
	if st["config"] == nil {
		return "", fmt.Errorf("run Setup first so the session knows which headset to use")
	}
	if c, ok := st["compatible"].(map[string]any); ok && !c["ok"].(bool) {
		return "", fmt.Errorf("Setup found a problem: %v", c["issues"])
	}
	if m, _ := st["missingPrograms"].([]string); len(m) > 0 {
		return "", fmt.Errorf("programs are missing (%s). Run BUILD-RELEASE.cmd or reinstall the release", strings.Join(m, ", "))
	}
	cmd := psFile("start-vrchat-trial.ps1", "-ManualSession")
	if err := cmd.Start(); err != nil {
		return "", err
	}
	wrapperMu.Lock()
	wrapperProc, wrapperDone = cmd.Process, false
	wrapperMu.Unlock()
	go func() {
		cmd.Wait()
		wrapperMu.Lock()
		wrapperDone = true
		wrapperMu.Unlock()
	}()
	return "Starting. Approve the Windows administrator prompt; a PowerShell window opens and must stay open.", nil
}

func runCapture(cmd *exec.Cmd, timeout time.Duration) string {
	type res struct {
		b   []byte
		err error
	}
	ch := make(chan res, 1)
	go func() { b, err := cmd.CombinedOutput(); ch <- res{b, err} }()
	select {
	case r := <-ch:
		out := strings.TrimSpace(decodeText(r.b))
		if r.err != nil && out == "" {
			out = r.err.Error()
		}
		return out
	case <-time.After(timeout):
		return "Still running in the background; watch the status panel."
	}
}

func openDebugTool() string {
	for _, p := range []string{
		`C:\Program Files\Meta Horizon\Support\oculus-diagnostics\OculusDebugTool.exe`,
		`C:\Program Files\Oculus\Support\oculus-diagnostics\OculusDebugTool.exe`,
	} {
		if fileExists(p) {
			exec.Command(p).Start()
			return "Oculus Debug Tool opened. Set 'Bypass Proximity Sensor Check' to On (after the session says Running), and close it before stopping."
		}
	}
	return "Oculus Debug Tool was not found in the Meta Horizon folder."
}

// ---------- setup wizard ----------

type pnpDevice struct {
	InstanceId   string `json:"InstanceId"`
	FriendlyName string `json:"FriendlyName"`
	Class        string `json:"Class"`
}
type gpuInfo struct {
	Name          string `json:"Name"`
	DriverVersion string `json:"DriverVersion"`
	PNPDeviceID   string `json:"PNPDeviceID"`
}

func snapshotDevices() ([]pnpDevice, error) {
	out, err := psCommand(`Get-PnpDevice -PresentOnly | Select-Object InstanceId,FriendlyName,Class | ConvertTo-Json -Compress`).Output()
	if err != nil {
		return nil, fmt.Errorf("device list failed: %v", err)
	}
	var list []pnpDevice
	if err := json.Unmarshal([]byte(strings.TrimSpace(decodeText(out))), &list); err != nil {
		return nil, fmt.Errorf("device list unreadable: %v", err)
	}
	return list, nil
}

func gpus() []gpuInfo {
	out, err := psCommand(`@(Get-CimInstance Win32_VideoController | Select-Object Name,DriverVersion,PNPDeviceID) | ConvertTo-Json -Compress`).Output()
	if err != nil {
		return nil
	}
	t := strings.TrimSpace(decodeText(out))
	var list []gpuInfo
	if strings.HasPrefix(t, "{") {
		var one gpuInfo
		json.Unmarshal([]byte(t), &one)
		return []gpuInfo{one}
	}
	json.Unmarshal([]byte(t), &list)
	return list
}

var (
	reUID      = regexp.MustCompile(`(?i)UID(\d+)`)
	reSerial   = regexp.MustCompile(`^[A-Za-z0-9]{6,32}$`)
	reMetaSer  = regexp.MustCompile(`(?:hmd_serial=|Proximity Sensor for |HMDSerialNumber["' :=]+)([A-Za-z0-9]{8,20})`)
	reSteamSer = regexp.MustCompile(`"HMDSerialNumber"\s*:\s*"([A-Za-z0-9]{6,32})"`)
)

// headsetSerial finds the Rift S serial: Meta USB device IDs first, then Meta's logs, then SteamVR's settings.
func headsetSerial(devices []pnpDevice) (string, string) {
	for _, d := range devices {
		up := strings.ToUpper(d.InstanceId)
		if !strings.HasPrefix(up, `USB\VID_2833`) {
			continue
		}
		parts := strings.Split(d.InstanceId, `\`)
		if last := parts[len(parts)-1]; len(parts) == 3 && reSerial.MatchString(last) && len(last) >= 10 {
			return last, "USB device ID"
		}
	}
	logs, _ := filepath.Glob(filepath.Join(os.Getenv("LOCALAPPDATA"), "Oculus", "Service_*.txt"))
	sort.Sort(sort.Reverse(sort.StringSlice(logs)))
	for i, l := range logs {
		if i >= 5 {
			break
		}
		if m := reMetaSer.FindStringSubmatch(readText(l, 4*1024*1024)); m != nil {
			return m[1], "Meta runtime log"
		}
	}
	for _, p := range []string{filepath.Join(os.Getenv("ProgramFiles(x86)"), `Steam\config\steamvr.vrsettings`)} {
		if m := reSteamSer.FindStringSubmatch(readText(p, 0)); m != nil {
			return m[1], "SteamVR settings"
		}
	}
	return "", ""
}

func analyzeSetup() map[string]any {
	a, b, c := setupSnaps[1], setupSnaps[2], setupSnaps[3]
	set := func(l []pnpDevice) map[string]pnpDevice {
		m := map[string]pnpDevice{}
		for _, d := range l {
			m[strings.ToUpper(d.InstanceId)] = d
		}
		return m
	}
	sa, sb, sc := set(a), set(b), set(c)
	var headset []pnpDevice
	for k, d := range sa {
		if _, gone := sb[k]; gone {
			continue
		}
		if _, back := sc[k]; back {
			headset = append(headset, d)
		}
	}
	sort.Slice(headset, func(i, j int) bool {
		return headset[i].Class+headset[i].InstanceId < headset[j].Class+headset[j].InstanceId
	})
	res := map[string]any{"devices": headset, "gpus": setupGPU}
	var id identity
	oculusUSB := 0
	for _, d := range headset {
		up := strings.ToUpper(d.InstanceId)
		if strings.EqualFold(d.Class, "Monitor") && strings.HasPrefix(up, `DISPLAY\`) && id.MonitorInstance == "" {
			id.MonitorInstance = d.InstanceId
			if m := reUID.FindStringSubmatch(d.InstanceId); m != nil {
				id.TargetID, _ = strconv.Atoi(m[1])
			}
		}
		if strings.Contains(up, "VID_2833") {
			oculusUSB++
		}
	}
	for _, g := range setupGPU {
		if strings.Contains(strings.ToUpper(g.PNPDeviceID), "VEN_8086") {
			id.GPUName = g.Name
			id.GPUPnpMatch = pnpVenDev(g.PNPDeviceID)
		}
	}
	if id.GPUName == "" && len(setupGPU) > 0 {
		id.GPUName, id.GPUPnpMatch = setupGPU[0].Name, pnpVenDev(setupGPU[0].PNPDeviceID)
	}
	if oculusUSB > 0 {
		id.HeadsetModel = "Oculus/Meta USB headset (" + strconv.Itoa(oculusUSB) + " devices)"
	}
	id.HeadsetSerial, id.SerialSource = headsetSerial(headset)
	warnings := []string{}
	if len(headset) == 0 {
		warnings = append(warnings, "No devices disappeared and came back. Unplug the headset fully (USB and DisplayPort) at step 2, and plug it back in at step 3.")
	}
	if id.MonitorInstance == "" {
		warnings = append(warnings, "No headset display was found. The Rift S display only appears while the Meta Horizon app/runtime is running and the headset is awake: open the Meta Horizon app, wait for the headset light, then run Setup again.")
	}
	if oculusUSB == 0 && len(headset) > 0 {
		warnings = append(warnings, "No Meta/Oculus USB devices (VID_2833) were among the changed devices.")
	}
	res["identity"] = id
	res["warnings"] = warnings
	res["compatible"] = compatible(id)
	return res
}

func pnpVenDev(p string) string {
	m := regexp.MustCompile(`(?i)VEN_[0-9A-F]{4}&DEV_[0-9A-F]{4}`).FindString(p)
	return strings.ToUpper(m)
}

// ---------- http ----------

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(v)
}

func api(h func(r *http.Request) (any, error)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("X-ArcRift-Token") != token {
			http.Error(w, "forbidden", http.StatusForbidden)
			return
		}
		if r.URL.Path != "/api/status" && r.Method != http.MethodPost {
			http.Error(w, "POST required", http.StatusMethodNotAllowed)
			return
		}
		lastHitMu.Lock()
		lastHit = time.Now()
		lastHitMu.Unlock()
		v, err := h(r)
		if err != nil {
			writeJSON(w, map[string]any{"ok": false, "message": err.Error()})
			return
		}
		writeJSON(w, v)
	}
}

func main() {
	exe, _ := os.Executable()
	root = filepath.Dir(exe)
	if len(os.Args) > 1 && os.Args[1] == "--root" && len(os.Args) > 2 {
		root = os.Args[2]
	}
	b := make([]byte, 16)
	rand.Read(b)
	token = hex.EncodeToString(b)

	mux := http.NewServeMux()
	sub, _ := fs.Sub(webFiles, "web")
	mux.Handle("/", http.FileServer(http.FS(sub)))
	mux.HandleFunc("/api/status", api(func(r *http.Request) (any, error) { return status(), nil }))
	mux.HandleFunc("/api/start", api(func(r *http.Request) (any, error) {
		m, err := startSession()
		if err != nil {
			return nil, err
		}
		return map[string]any{"ok": true, "message": m}, nil
	}))
	mux.HandleFunc("/api/stop", api(func(r *http.Request) (any, error) {
		if !fileExists(filepath.Join(root, "active-test.xml")) {
			return nil, fmt.Errorf("no active session")
		}
		return map[string]any{"ok": true, "message": runCapture(psFile("stop-arc-rift.ps1"), 20*time.Second)}, nil
	}))
	mux.HandleFunc("/api/recover", api(func(r *http.Request) (any, error) {
		if status()["state"] != "recovery" {
			return nil, fmt.Errorf("recovery is only for a session whose window closed before cleanup finished")
		}
		cmd := psFile("recover-manual-session.ps1")
		if err := cmd.Start(); err != nil {
			return nil, err
		}
		go cmd.Wait()
		return map[string]any{"ok": true, "message": "Recovery started. Approve the administrator prompt; status updates when it finishes."}, nil
	}))
	mux.HandleFunc("/api/open-folder", api(func(r *http.Request) (any, error) {
		d := r.URL.Query().Get("which")
		target := root
		if d == "session" {
			if s := latestSessionDir(); s != "" {
				target = s
			}
		}
		exec.Command("explorer.exe", target).Start()
		return map[string]any{"ok": true}, nil
	}))
	mux.HandleFunc("/api/debug-tool", api(func(r *http.Request) (any, error) {
		return map[string]any{"ok": true, "message": openDebugTool()}, nil
	}))
	mux.HandleFunc("/api/setup/step", api(func(r *http.Request) (any, error) {
		step, _ := strconv.Atoi(r.URL.Query().Get("n"))
		if step < 1 || step > 3 {
			return nil, fmt.Errorf("bad step")
		}
		list, err := snapshotDevices()
		if err != nil {
			return nil, err
		}
		setupMu.Lock()
		defer setupMu.Unlock()
		setupSnaps[step] = list
		if step == 1 {
			setupGPU = gpus()
			delete(setupSnaps, 2)
			delete(setupSnaps, 3)
		}
		res := map[string]any{"ok": true, "count": len(list)}
		if step == 3 {
			if setupSnaps[1] == nil || setupSnaps[2] == nil {
				return nil, fmt.Errorf("run steps 1 and 2 first")
			}
			res["result"] = analyzeSetup()
		}
		return res, nil
	}))
	mux.HandleFunc("/api/setup/save", api(func(r *http.Request) (any, error) {
		var id identity
		if err := json.NewDecoder(r.Body).Decode(&id); err != nil || id.MonitorInstance == "" {
			return nil, fmt.Errorf("nothing to save: no headset display detected")
		}
		b, _ := json.MarshalIndent(id, "", "  ")
		if err := os.WriteFile(filepath.Join(root, "arcrift-config.json"), b, 0644); err != nil {
			return nil, err
		}
		return map[string]any{"ok": true, "message": "Saved to arcrift-config.json"}, nil
	}))

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		fatal("Could not open the local UI port: " + err.Error())
	}
	url := fmt.Sprintf("http://127.0.0.1:%d/#%s", ln.Addr().(*net.TCPAddr).Port, token)
	go http.Serve(ln, mux)

	if !fileExists(filepath.Join(root, "test-ovr-d3d11.ps1")) {
		fatal("ArcRift Control must be inside the ArcRiftLab folder (test-ovr-d3d11.ps1 not found next to it).")
	}
	edge := openWindow(url)
	if edge != nil {
		start := time.Now()
		edge.Wait()
		if time.Since(start) > 5*time.Second {
			os.Exit(0) // window closed
		}
	}
	// Edge handed off or a normal browser is used: exit after the page stops polling.
	for {
		time.Sleep(5 * time.Second)
		lastHitMu.Lock()
		idle := time.Since(lastHit)
		lastHitMu.Unlock()
		if idle > 45*time.Second {
			os.Exit(0)
		}
	}
}

func openWindow(url string) *os.Process {
	profile := filepath.Join(os.Getenv("LOCALAPPDATA"), "ArcRiftControl", "window")
	os.MkdirAll(profile, 0755)
	for _, p := range []string{
		filepath.Join(os.Getenv("ProgramFiles(x86)"), `Microsoft\Edge\Application\msedge.exe`),
		filepath.Join(os.Getenv("ProgramFiles"), `Microsoft\Edge\Application\msedge.exe`),
	} {
		if fileExists(p) {
			cmd := exec.Command(p, "--app="+url, "--user-data-dir="+profile, "--window-size=1180,820",
				"--no-first-run", "--no-default-browser-check", "--disable-features=Translate")
			if cmd.Start() == nil {
				return cmd.Process
			}
		}
	}
	hidden(exec.Command("rundll32.exe", "url.dll,FileProtocolHandler", url)).Start()
	return nil
}

func fatal(msg string) {
	user32 := syscall.NewLazyDLL("user32.dll")
	mb := user32.NewProc("MessageBoxW")
	t, _ := syscall.UTF16PtrFromString(msg)
	c, _ := syscall.UTF16PtrFromString("ArcRift Control")
	mb.Call(0, uintptr(unsafe.Pointer(t)), uintptr(unsafe.Pointer(c)), 0x10)
	os.Exit(1)
}
