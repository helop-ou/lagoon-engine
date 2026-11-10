#include <metal_stdlib>
using namespace metal;

// Blends one premultiplied BGRA subtitle piece into a decoded 4:2:0 frame in
// place, for Picture in Picture, where the host's overlay is not shown.
//
// One thread handles one 2x2 luma block under the piece, which is one chroma
// sample. Blending is in code values, as a burn-in does. The piece's colour
// is taken to the frame's encoding first: gamma-encoded as it is for SDR,
// and for PQ and HLG linearised, moved to BT.2020 and scaled so white lands
// at `whiteNits`, never at the frame's peak.
//
// Layout must match `SubtitleFrameCompositor.Parameters` field for field.
struct LagoonSubtitleBlendParameters {
    uint originX;     // even, in luma pixels
    uint originY;     // even
    uint width;       // even
    uint height;      // even
    uint fullRange;
    uint depth;       // 8 → NV12 texels, 10 → P010 texels
    uint transfer;    // 0 SDR, 1 PQ, 2 HLG
    uint matrix;      // 0 BT.709, 1 BT.2020, 2 BT.601
    float whiteNits;  // PQ: nits for subtitle white. HLG: its scene light.
};

constant float PQ_M1 = 0.1593017578125f;
constant float PQ_M2 = 78.84375f;
constant float PQ_C1 = 0.8359375f;
constant float PQ_C2 = 18.8515625f;
constant float PQ_C3 = 18.6875f;

static inline float3 srgbToLinear(float3 c) {
    return select(pow((c + 0.055f) / 1.055f, 2.4f), c / 12.92f, c <= 0.04045f);
}

static inline float3 nitsToPQ(float3 nits) {
    float3 y = pow(max(nits, 0.0f) / 10000.0f, PQ_M1);
    return pow((PQ_C1 + PQ_C2 * y) / (1.0f + PQ_C3 * y), PQ_M2);
}

static inline float3 hlgOETF(float3 e) {
    const float a = 0.17883277f;
    const float b = 0.28466892f;
    const float c = 0.55991073f;
    return select(a * log(max(12.0f * e - b, 1e-6f)) + c, sqrt(3.0f * max(e, 0.0f)), e <= 1.0f / 12.0f);
}

// BT.709 primaries to BT.2020, linear light (BT.2087).
static inline float3 rec709ToRec2020(float3 c) {
    return float3(
        dot(c, float3(0.6274f, 0.3293f, 0.0433f)),
        dot(c, float3(0.0691f, 0.9195f, 0.0114f)),
        dot(c, float3(0.0164f, 0.0880f, 0.8956f))
    );
}

// R'G'B' to Y'CbCr, all in 0...1 with chroma centred on 0.5.
static inline float3 toYCbCr(float3 rgb, uint matrix) {
    float kr = matrix == 1 ? 0.2627f : (matrix == 2 ? 0.299f : 0.2126f);
    float kb = matrix == 1 ? 0.0593f : (matrix == 2 ? 0.114f : 0.0722f);
    float y = kr * rgb.r + (1.0f - kr - kb) * rgb.g + kb * rgb.b;
    return float3(y, (rgb.b - y) / (2.0f * (1.0f - kb)) + 0.5f, (rgb.r - y) / (2.0f * (1.0f - kr)) + 0.5f);
}

static inline float3 encoded(float3 srgb, constant LagoonSubtitleBlendParameters &p) {
    if (p.transfer == 0) { return toYCbCr(srgb, p.matrix); }
    float3 light = rec709ToRec2020(srgbToLinear(srgb));
    float3 signal = p.transfer == 1 ? nitsToPQ(light * p.whiteNits) : hlgOETF(light * p.whiteNits);
    return toYCbCr(signal, 1);
}

// A 0...1 component as the texel value the plane stores.
static inline float lumaTexel(float y, constant LagoonSubtitleBlendParameters &p) {
    float code = p.depth == 10
        ? (p.fullRange ? y * 1023.0f : 64.0f + 876.0f * y)
        : (p.fullRange ? y * 255.0f : 16.0f + 219.0f * y);
    return p.depth == 10 ? code * 64.0f / 65535.0f : code / 255.0f;
}

static inline float chromaTexel(float c, constant LagoonSubtitleBlendParameters &p) {
    float code = p.depth == 10
        ? (p.fullRange ? c * 1023.0f : 64.0f + 896.0f * c)
        : (p.fullRange ? c * 255.0f : 16.0f + 224.0f * c);
    return p.depth == 10 ? code * 64.0f / 65535.0f : code / 255.0f;
}

kernel void lagoonBlendSubtitle(
    texture2d<float, access::read> lumaIn [[texture(0)]],
    texture2d<float, access::write> lumaOut [[texture(1)]],
    texture2d<float, access::read> chromaIn [[texture(2)]],
    texture2d<float, access::write> chromaOut [[texture(3)]],
    texture2d<float, access::read> piece [[texture(4)]],
    constant LagoonSubtitleBlendParameters &p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x * 2 >= p.width || gid.y * 2 >= p.height) { return; }
    float cbSum = 0.0f;
    float crSum = 0.0f;
    float alphaSum = 0.0f;
    for (uint dy = 0; dy < 2; dy++) {
        for (uint dx = 0; dx < 2; dx++) {
            uint2 local = uint2(gid.x * 2 + dx, gid.y * 2 + dy);
            float4 texel = piece.read(local);
            float alpha = texel.a;
            if (alpha <= 0.0f) { continue; }
            float3 colour = encoded(clamp(texel.rgb / alpha, 0.0f, 1.0f), p);
            uint2 frame = uint2(p.originX, p.originY) + local;
            float y = lumaIn.read(frame).r;
            lumaOut.write(float4(alpha * lumaTexel(colour.x, p) + (1.0f - alpha) * y, 0, 0, 0), frame);
            cbSum += alpha * chromaTexel(colour.y, p);
            crSum += alpha * chromaTexel(colour.z, p);
            alphaSum += alpha;
        }
    }
    if (alphaSum <= 0.0f) { return; }
    uint2 site = uint2(p.originX / 2 + gid.x, p.originY / 2 + gid.y);
    float2 chroma = chromaIn.read(site).rg;
    float coverage = alphaSum / 4.0f;
    chromaOut.write(float4(cbSum / 4.0f + (1.0f - coverage) * chroma.x,
                           crSum / 4.0f + (1.0f - coverage) * chroma.y, 0, 0), site);
}
