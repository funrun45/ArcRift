@echo off
setlocal
rem ArcRift release build: compiles the bridge and helpers from .\source with Microsoft Visual C++,
rem then writes release-manifest.json (SHA-256 of every program the session script verifies).
set "VCVARS="
for %%E in (BuildTools Community Professional Enterprise) do if exist "C:\Program Files (x86)\Microsoft Visual Studio\2022\%%E\VC\Auxiliary\Build\vcvars64.bat" set "VCVARS=C:\Program Files (x86)\Microsoft Visual Studio\2022\%%E\VC\Auxiliary\Build\vcvars64.bat"
for %%E in (BuildTools Community Professional Enterprise) do if exist "C:\Program Files\Microsoft Visual Studio\2022\%%E\VC\Auxiliary\Build\vcvars64.bat" set "VCVARS=C:\Program Files\Microsoft Visual Studio\2022\%%E\VC\Auxiliary\Build\vcvars64.bat"
if not defined VCVARS (echo Visual Studio 2022 C++ Build Tools were not found. & pause & exit /b 1)
call "%VCVARS%" >nul || (echo Could not set up the compiler. & pause & exit /b 1)
cd /d "%~dp0source"
if not exist build mkdir build
echo Building arc_rift_bridge.dll ...
cl /nologo /EHsc /std:c++17 /W4 /O2 /MT /LD arc_rift_bridge.cpp /Fo:build\arc_rift_bridge.obj /Fe:..\arc_rift_bridge.dll /link /IMPLIB:build\arc_rift_bridge.lib dxgi.lib d3d11.lib user32.lib || goto fail
echo Building native_source_test.exe ...
cl /nologo /EHsc /std:c++17 /W4 /O2 native_source_test.cpp /Fo:build\native_source_test.obj /Fe:..\native_source_test.exe /link user32.lib || goto fail
echo Building native_source_session.exe ...
cl /nologo /EHsc /std:c++17 /W4 /O2 /DARC_RIFT_MANUAL_SESSION native_source_test.cpp /Fo:build\native_source_session.obj /Fe:..\native_source_session.exe /link user32.lib || goto fail
echo Building display_probe.exe ...
cl /nologo /EHsc /std:c++17 /W4 /O2 display_probe.cpp /Fo:build\display_probe.obj /Fe:..\display_probe.exe /link dxgi.lib d3d11.lib user32.lib windowsapp.lib || goto fail
echo Building bridge_selftest.exe ...
cl /nologo /EHsc /std:c++17 /W4 /O2 bridge_selftest.cpp /Fo:build\bridge_selftest.obj /Fe:..\bridge_selftest.exe || goto fail
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0write-release-manifest.ps1" || goto fail
echo.
echo BUILD OK - release-manifest.json written.
pause
exit /b 0
:fail
echo.
echo BUILD FAILED - see the messages above.
pause
exit /b 1
