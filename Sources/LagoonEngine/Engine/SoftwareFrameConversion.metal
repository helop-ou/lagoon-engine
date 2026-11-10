#include <metal_stdlib>
using namespace metal;

// GPU output stage for software-decoded planar video: 4:2:0, 4:2:2 or
// 4:4:4, 8, 10 or 12 bits, always written as 4:2:0.
//
// One thread handles one 2x2 luma block, which is exactly one chroma sample
// in 4:2:0, so the kernel reads four luma samples and the chroma samples
// under the block, and writes four luma and one interleaved chroma pair.
// Codes are taken to 10 bits first and chroma is averaged down to 4:2:0, so
// both modes see 10-bit 4:2:0. Two modes:
//
//   toneMap == 0: repack planar little-endian 10-bit (low bits) into P010
//                 (high bits, interleaved chroma). No colour change.
//   toneMap == 1: PQ BT.2020 → BT.709 SDR, the BT.2390 EETF on luminance,
//                 then a chroma-preserving fit into the 709 gamut.
//
// Layout must match `MetalFrameConverter.Parameters` field for field.
struct LagoonPlanarConvertParameters {
    uint width;          // luma width, even
    uint height;         // luma height, even
    uint lumaStride;     // uint16 elements per source luma row
    uint chromaStride;   // uint16 elements per source chroma row
    uint lumaOffset;     // uint16 elements from the buffer base
    uint cbOffset;
    uint crOffset;
    uint fullRange;      // source range
    uint toneMap;
    uint outputDepth;    // 10 → P010 texels, 8 → NV12 texels
    float sourcePeakNits;
    float targetPeakNits;
    uint sourceDepth;    // 8 reads bytes, 10 or 12 reads uint16 elements
    uint chromaShiftX;   // log2 horizontal chroma subsampling: 1 or 0
    uint chromaShiftY;   // log2 vertical chroma subsampling: 1 or 0
};

// One sample's code at 10 bits. `index` counts source elements.
static inline uint sampleCode(device const uint16_t *source, uint index, uint depth) {
    if (depth == 8) { return uint(((device const uchar *)source)[index]) << 2; }
    const uint code = uint(source[index]);
    if (depth == 12) { return min((code + 2) >> 2, 1023u); }
    return min(code, 1023u);
}

constant float PQ_M1 = 0.1593017578125f;
constant float PQ_M2 = 78.84375f;
constant float PQ_C1 = 0.8359375f;
constant float PQ_C2 = 18.8515625f;
constant float PQ_C3 = 18.6875f;

static inline float pqToNits(float e) {
    float p = pow(max(e, 0.0f), 1.0f / PQ_M2);
    float numerator = max(p - PQ_C1, 0.0f);
    float denominator = max(PQ_C2 - PQ_C3 * p, 1e-6f);
    return 10000.0f * pow(numerator / denominator, 1.0f / PQ_M1);
}

static inline float nitsToPQ(float nits) {
    float y = pow(max(nits, 0.0f) / 10000.0f, PQ_M1);
    return pow((PQ_C1 + PQ_C2 * y) / (1.0f + PQ_C3 * y), PQ_M2);
}

// ITU-R BT.2390 EETF, in the PQ domain normalised to the source peak. Below
// the knee the signal passes unchanged; above it a Hermite spline compresses
// the source's highlights into what the target peak can show.
static inline float toneMapLuminance(float nits, float peakSourcePQ, float maxLum) {
    float e1 = min(nitsToPQ(nits) / peakSourcePQ, 1.0f);
    float ks = 1.5f * maxLum - 0.5f;
    float e2 = e1;
    if (e1 > ks) {
        float t = (e1 - ks) / (1.0f - ks);
        float t2 = t * t;
        float t3 = t2 * t;
        e2 = (2.0f * t3 - 3.0f * t2 + 1.0f) * ks
            + (t3 - 2.0f * t2 + t) * (1.0f - ks)
            + (-2.0f * t3 + 3.0f * t2) * maxLum;
    }
    return pqToNits(e2 * peakSourcePQ);
}

constant float3 BT2020_LUMA = float3(0.2627f, 0.6780f, 0.0593f);
constant float3 BT709_LUMA = float3(0.2126f, 0.7152f, 0.0722f);
constant float3x3 BT2020_TO_BT709 = float3x3(
    float3(1.6605f, -0.1246f, -0.0182f),
    float3(-0.5876f, 1.1329f, -0.1006f),
    float3(-0.0728f, -0.0083f, 1.1187f)
);

kernel void lagoonConvertPlanar10(
    device const uint16_t *source [[buffer(0)]],
    constant LagoonPlanarConvertParameters &p [[buffer(1)]],
    texture2d<float, access::write> outputLuma [[texture(0)]],
    texture2d<float, access::write> outputChroma [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    const uint x = gid.x * 2;
    const uint y = gid.y * 2;
    if (x >= p.width || y >= p.height) { return; }

    const uint lumaCodes[4] = {
        sampleCode(source, p.lumaOffset + y * p.lumaStride + x, p.sourceDepth),
        sampleCode(source, p.lumaOffset + y * p.lumaStride + x + 1, p.sourceDepth),
        sampleCode(source, p.lumaOffset + (y + 1) * p.lumaStride + x, p.sourceDepth),
        sampleCode(source, p.lumaOffset + (y + 1) * p.lumaStride + x + 1, p.sourceDepth),
    };
    // The chroma samples under this block: one in 4:2:0, two stacked in
    // 4:2:2, four in 4:4:4, averaged.
    const uint spanX = 2u >> p.chromaShiftX;
    const uint spanY = 2u >> p.chromaShiftY;
    uint cbSum = 0;
    uint crSum = 0;
    for (uint dy = 0; dy < spanY; dy++) {
        for (uint dx = 0; dx < spanX; dx++) {
            const uint index = (gid.y * spanY + dy) * p.chromaStride + gid.x * spanX + dx;
            cbSum += sampleCode(source, p.cbOffset + index, p.sourceDepth);
            crSum += sampleCode(source, p.crOffset + index, p.sourceDepth);
        }
    }
    const uint count = spanX * spanY;
    const uint cbCode = (cbSum + count / 2) / count;
    const uint crCode = (crSum + count / 2) / count;

    // Destination texel normalisation: P010 carries the 10-bit code in the
    // high bits of a 16-bit word; NV12 is a plain 8-bit code.
    const float codeScale = p.outputDepth == 10 ? (64.0f / 65535.0f) : (1.0f / 255.0f);
    const float depthScale = p.outputDepth == 10 ? 1.0f : (1.0f / 4.0f);

    if (p.toneMap == 0) {
        outputLuma.write(float(lumaCodes[0]) * depthScale * codeScale, uint2(x, y));
        outputLuma.write(float(lumaCodes[1]) * depthScale * codeScale, uint2(x + 1, y));
        outputLuma.write(float(lumaCodes[2]) * depthScale * codeScale, uint2(x, y + 1));
        outputLuma.write(float(lumaCodes[3]) * depthScale * codeScale, uint2(x + 1, y + 1));
        outputChroma.write(
            float4(float(cbCode), float(crCode), 0.0f, 0.0f) * depthScale * codeScale,
            gid
        );
        return;
    }

    float lumaOffset;
    float lumaScale;
    float chromaScale;
    if (p.fullRange != 0) {
        lumaOffset = 0.0f;
        lumaScale = 1.0f / 1023.0f;
        chromaScale = 1.0f / 1023.0f;
    } else {
        lumaOffset = 64.0f;
        lumaScale = 1.0f / 876.0f;
        chromaScale = 1.0f / 896.0f;
    }
    const float cb = (float(cbCode) - 512.0f) * chromaScale;
    const float cr = (float(crCode) - 512.0f) * chromaScale;
    const float peakSourcePQ = nitsToPQ(p.sourcePeakNits);
    const float maxLum = nitsToPQ(p.targetPeakNits) / peakSourcePQ;

    float encodedLuma[4];
    float3 encodedSum = float3(0.0f);
    for (uint i = 0; i < 4; i++) {
        const float yN = clamp((float(lumaCodes[i]) - lumaOffset) * lumaScale, 0.0f, 1.0f);
        // BT.2020 non-constant-luminance Y'CbCr → R'G'B' (still PQ-encoded).
        const float3 rgbPQ = clamp(float3(
            yN + 1.4746f * cr,
            yN - 0.16455f * cb - 0.57135f * cr,
            yN + 1.8814f * cb
        ), 0.0f, 1.0f);
        float3 linear = float3(pqToNits(rgbPQ.r), pqToNits(rgbPQ.g), pqToNits(rgbPQ.b));
        const float luminance = dot(linear, BT2020_LUMA);
        const float mapped = toneMapLuminance(luminance, peakSourcePQ, maxLum);
        linear *= luminance > 1e-4f ? mapped / luminance : 0.0f;

        float3 rgb = (BT2020_TO_BT709 * linear) / p.targetPeakNits;
        // Luminance is invariant under the primaries change, so anything
        // over 1.0 is chroma the 709 gamut cannot hold: pull it toward the
        // luminance axis just far enough to fit, rather than clipping hue.
        const float luma709 = dot(rgb, BT709_LUMA);
        const float peak = max(max(rgb.r, rgb.g), rgb.b);
        if (peak > 1.0f && peak > luma709) {
            rgb = mix(rgb, float3(luma709), (peak - 1.0f) / (peak - luma709));
        }
        rgb = clamp(rgb, 0.0f, 1.0f);
        const float3 encoded = pow(rgb, 1.0f / 2.4f);
        encodedLuma[i] = dot(encoded, BT709_LUMA);
        encodedSum += encoded;
    }
    const float3 encodedMean = encodedSum * 0.25f;
    const float meanLuma = dot(encodedMean, BT709_LUMA);
    const float cbOut = (encodedMean.b - meanLuma) / 1.8556f;
    const float crOut = (encodedMean.r - meanLuma) / 1.5748f;

    // Limited-range 10-bit codes, then scaled for the destination texel.
    const float outScale = depthScale * codeScale;
    outputLuma.write((64.0f + 876.0f * encodedLuma[0]) * outScale, uint2(x, y));
    outputLuma.write((64.0f + 876.0f * encodedLuma[1]) * outScale, uint2(x + 1, y));
    outputLuma.write((64.0f + 876.0f * encodedLuma[2]) * outScale, uint2(x, y + 1));
    outputLuma.write((64.0f + 876.0f * encodedLuma[3]) * outScale, uint2(x + 1, y + 1));
    outputChroma.write(
        float4(512.0f + 896.0f * cbOut, 512.0f + 896.0f * crOut, 0.0f, 0.0f) * outScale,
        gid
    );
}
