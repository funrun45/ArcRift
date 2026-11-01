#pragma once
// Bounded full-surface readback for local diagnostics; never captures the desktop.
#include <windows.h>
#include <d3d11.h>
#include <wrl/client.h>
#include <cstdint>
struct TextureSummary {
    UINT width = 0, height = 0;
    uint64_t pixels = 0, nonblack = 0, greenDominant = 0;
    unsigned maxRGB[3]{}, maxAlpha = 0;
};
inline HRESULT SummarizeTexture(ID3D11Device* device, ID3D11DeviceContext* context,
    ID3D11Texture2D* source, TextureSummary& out) {
    using Microsoft::WRL::ComPtr;
    D3D11_TEXTURE2D_DESC desc{};
    source->GetDesc(&desc);
    bool bgra = desc.Format == DXGI_FORMAT_B8G8R8A8_UNORM || desc.Format == DXGI_FORMAT_B8G8R8A8_UNORM_SRGB || desc.Format == DXGI_FORMAT_B8G8R8A8_TYPELESS;
    bool rgba = desc.Format == DXGI_FORMAT_R8G8B8A8_UNORM || desc.Format == DXGI_FORMAT_R8G8B8A8_UNORM_SRGB || desc.Format == DXGI_FORMAT_R8G8B8A8_TYPELESS;
    if ((!rgba && !bgra) || desc.SampleDesc.Count != 1 || desc.MipLevels != 1 || desc.ArraySize != 1 || desc.Width > 4096 || desc.Height > 4096) return E_INVALIDARG;
    out = {};
    out.width = desc.Width; out.height = desc.Height;
    desc.Usage = D3D11_USAGE_STAGING;
    desc.BindFlags = desc.MiscFlags = 0;
    desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    ComPtr<ID3D11Texture2D> staging;
    HRESULT hr = device->CreateTexture2D(&desc, nullptr, &staging);
    if (FAILED(hr)) return hr;
    context->CopyResource(staging.Get(), source);
    ComPtr<ID3D11Query> done;
    D3D11_QUERY_DESC query{D3D11_QUERY_EVENT, 0};
    hr = device->CreateQuery(&query, &done);
    if (FAILED(hr)) return hr;
    context->End(done.Get());
    context->Flush();
    ULONGLONG deadline = GetTickCount64() + 1000;
    while ((hr = context->GetData(done.Get(), nullptr, 0, 0)) == S_FALSE && GetTickCount64() < deadline) Sleep(1);
    if (hr != S_OK) return hr == S_FALSE ? HRESULT_FROM_WIN32(WAIT_TIMEOUT) : hr;
    D3D11_MAPPED_SUBRESOURCE mapped{};
    hr = context->Map(staging.Get(), 0, D3D11_MAP_READ, D3D11_MAP_FLAG_DO_NOT_WAIT, &mapped);
    if (FAILED(hr)) return hr;
    for (UINT y = 0; y < desc.Height; ++y) {
        auto row = static_cast<const unsigned char*>(mapped.pData) + size_t(y) * mapped.RowPitch;
        for (UINT x = 0; x < desc.Width; ++x) {
            auto p = row + size_t(x) * 4;
            unsigned rgb[3] = {p[bgra ? 2 : 0], p[1], p[bgra ? 0 : 2]};
            ++out.pixels;
            if (rgb[0] || rgb[1] || rgb[2]) ++out.nonblack;
            if (rgb[1] > rgb[0] && rgb[1] > rgb[2]) ++out.greenDominant;
            for (int c = 0; c < 3; ++c) if (rgb[c] > out.maxRGB[c]) out.maxRGB[c] = rgb[c];
            if (p[3] > out.maxAlpha) out.maxAlpha = p[3];
        }
    }
    context->Unmap(staging.Get(), 0);
    return S_OK;
}
