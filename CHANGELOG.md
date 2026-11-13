# Changelog

## 1.3 (2026-11-13)

Covers everything since 1.1.2, including the in-between builds 1.2 and 1.2.1, which were never published.

### New: room boundary
Meta's Guardian cannot be set up on Intel Arc (its setup runs inside Meta's Dash, which needs Vulkan, and Meta
does not support Vulkan on Arc cards). ArcRift now draws a boundary itself with a new helper, `arcrift_boundary.exe`.
- **Box around me**: pick a size (1.5 × 1.5 m up to 4 × 3 m), stand in the middle facing forward, and a box is placed
  around you. The box also becomes SteamVR's play area, centred where you stood and facing the way you faced, so
  games get the whole box.
- **Draw boundary**: hold a controller's trigger and trace the edge of your play space for an exact shape.
- Cyan grid walls fade in when your head or hands come within about 75 cm of an edge.
- **Use saved boundary** brings a box or traced outline back in a later session. **Remove boundary** takes it away
  and puts back SteamVR's previous boundary data.
- `boundary-log.txt` records what SteamVR saw (controllers, tracking, headset height) when something doesn't work.
- Asking for Meta Guardian setup now gives a clear message instead of starting a session that can only crash.

### Session stopping
- A session now stops on low frame rate only when the headset is below **5 fps** (fewer than 120 frames in 24 s,
  which includes a full freeze). Before, it stopped below 45 fps twice in a row, or after 3 s with no frames.
- SteamVR sync errors (a game running slowly) are only written to `sync-hiccups.txt`. They no longer stop a
  session.

### Recovery
- If the PC was shut down, restarted or crashed during a session, just press **Start VR session**: the session
  restores the unrestored session first, then starts a new one.
- This also works when the unrestored session came from another ArcRift copy, such as an older release folder.
- A session that ended in its first seconds, before it changed anything, no longer leaves a "Needs recovery" marker
  that blocks Start.
- A leftover `active-test.lock` from an interrupted session no longer makes every later Start fail.
- The recovery check reads active displays the same way as the session script, and keeps two graphics adapters
  with the same display target ID apart.

### Other Intel Arc cards (B580 and others)
These cards are still untested, and the one B580 report (headset stuck at 1920x1080 60 Hz) is **not fixed yet**.
This release adds:
- The bridge now checks that the headset is plugged into the graphics card it expects, using what Windows reports.
  This fixes PCs that have processor graphics plus an Arc card, where Setup could pick the wrong one.
- The session waits up to 45 s (was 6 s, then 20 s) for the headset's native display mode. PCs that are ready
  sooner carry on straight away.
- Each session folder gets a `system-info.txt` (graphics card, driver, Windows build) for bug reports.
- When the headset display can't be matched, the bridge log and session log say why.

### Fixes
- Start no longer fails on PCs that run more than one `explorer.exe` (for example with "Launch folder windows in a
  separate process" turned on). Only the Explorer that owns the desktop is checked.
- The bridge handles Meta rebuilding its compositor (with a new D3D11 device) cleanly, without mixing resources from
  the old and new devices.
- A session won't start while SteamVR or VRChat is already open, and it names the program to close.

### Build
- `BUILD-RELEASE.cmd` also builds `arcrift_boundary.exe`, and `release-manifest.json` now includes its hash.
- Includes Valve's OpenVR header (`source/openvr/openvr.h`, BSD-3-Clause, unmodified). At runtime the boundary
  helper loads SteamVR's own `openvr_api.dll`.

## 1.1.2 (2026-11-02)
- Waits for a sleeping headset to wake before switching Meta over, and retries with Meta's normal runtime if needed.
- No more full-frame GPU readback every 1.5 s; SteamVR's pose log is trimmed so long sessions don't fill the disk.
- A Steam restart or update no longer ends the session; SteamVR works from any Steam library.
- Lighter watchdog, PresentMon for any game, the **Restoring…** status and the **Clear…** button.

## 1.1.1 (2026-11-01)
- Retries automatically when the headset is still waking up; game-neutral app UI; screenshot in the README.

## 1.1.0
- First public release: Oculus Rift S on Intel Arc (source, scripts, docs).
