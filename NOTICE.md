# Notices and credits

ArcRift (ArcRiftLab / ArcRift Control), copyright (c) 2026 funrun, released under the MIT License (see `LICENSE`).
Free, non-commercial community project. Not affiliated with or endorsed by Meta, Oculus, Intel or Valve.
"Oculus", "Rift", "Meta", "Intel", "Arc" and "SteamVR" are trademarks of their respective owners and are used
here only to describe compatibility.

## Third-party work

| Component | Author | Licence | File |
|---|---|---|---|
| DirectDisplay interface definitions used by the bridge (`source\ovr_direct_display.h`, `source\arc_rift_bridge.cpp`) | Bnuuy Solutions, [OculusDirectDisplayAdditions](https://github.com/BnuuySolutions/OculusDirectDisplayAdditions) | MIT | `OculusDirectDisplayAdditions-LICENSE.txt` |
| OpenVR API header (`source\openvr\openvr.h`, unmodified), used by `arcrift_boundary.exe`; it loads SteamVR's own `openvr_api.dll` at runtime | Valve Corporation, [OpenVR](https://github.com/ValveSoftware/openvr) | BSD-3-Clause | `source\openvr\LICENSE` |
| PresentMon 2.3.1 (`PresentMon.exe`, unmodified official release) | Intel GameTechDev | MIT | `PresentMon-LICENSE.txt` |
| Rift S display timing research behind `rift-s-native-test.edid` / `source\make_edid.py` | [OpenHMD](https://github.com/OpenHMD/OpenHMD) contributors, [thaytan/RiftS-Experiments](https://github.com/thaytan/RiftS-Experiments) | credit only (no code included) | — |

## Not included

- No Meta, Oculus, SteamVR or Intel driver files are included or modified. During a session, three Meta streaming
  plugins are temporarily renamed on the user's own PC and restored afterwards, and Meta's runtime is pointed
  at this folder's bridge DLL through its `DirectDisplayDLL` setting, which is also restored.
- No Oculus SDK headers or Intel Graphics Control Library files are included.

## Warning from the upstream project

Bnuuy Solutions notes that their reverse-engineered DirectDisplay code "could" leave OVRServer (Meta's runtime)
in a state that may require a system restart. ArcRift adds automatic detection and restore for that case, but
the risk is not zero.
