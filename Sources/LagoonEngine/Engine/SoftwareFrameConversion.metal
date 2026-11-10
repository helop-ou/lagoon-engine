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

// One sample as stored, at the source's depth. `index` counts elements.
static inline int rawSample(device const uint16_t *source, uint index, uint depth) {
    if (depth == 8) { return int(((device const uchar *)source)[index]); }
    return int(source[index]);
}

// A source-depth sample as a 10-bit code.
static inline uint codeFromRaw(int raw, uint depth) {
    const uint code = uint(max(raw, 0));
    if (depth == 8) { return code << 2; }
    if (depth == 12) { return min((code + 2) >> 2, 1023u); }
    return min(code, 1023u);
}

// AV1 film grain (AV1 specification 7.18.3.5), added to each source sample
// before anything else, so it lands exactly where dav1d would put it. The
// templates, scaling tables and per-block offsets come from `AV1FilmGrain`.
// Layout must match `AV1FilmGrain.Parameters` field for field.
struct LagoonFilmGrainParameters {
    uint applyLuma;
    uint applyCb;
    uint applyCr;
    uint chromaFromLuma;
    uint overlap;
    uint restrictedRange;
    uint identityMatrix;
    uint blockColumns;
    uint scalingSize;
    int scalingShift;
    int bitDepth;
    int cbMult;
    int crMult;
    int cbLumaMult;
    int crLumaMult;
    int cbOffset;
    int crOffset;
};

struct LagoonFilmGrainTables {
    device const short *luma;
    device const short *cb;
    device const short *cr;
    device const uchar *scaling;
    device const uchar *offsets;
};

constant int GRAIN_TEMPLATE_WIDTH = 82;

static inline int grainRound2(int x, int shift) { return (x + ((1 << shift) >> 1)) >> shift; }

// The template sample for a block (or the one left of or above it, by
// `previousX` and `previousY`) at a position inside the current block.
static inline int grainTemplate(device const short *lut, device const uchar *offsets, uint columns,
                                int bx, int by, int previousX, int previousY,
                                int x, int y, int sx, int sy) {
    const int random = int(offsets[(by - previousY) * int(columns) + (bx - previousX)]);
    const int offsetX = 3 + (2 >> sx) * (3 + (random >> 4));
    const int offsetY = 3 + (2 >> sy) * (3 + (random & 15));
    return int(lut[(offsetY + y + (32 >> sy) * previousY) * GRAIN_TEMPLATE_WIDTH
                   + offsetX + x + (32 >> sx) * previousX]);
}

static inline int blendGrain(int old, int current, int oldWeight, int currentWeight, int low, int high) {
    return clamp(grainRound2(old * oldWeight + current * currentWeight, 5), low, high);
}

// The grain at one sample of a plane, blended with the neighbouring blocks'
// where the first two columns or rows overlap them.
static inline int grainAt(device const short *lut, device const uchar *offsets,
                          constant LagoonFilmGrainParameters &g,
                          int x, int y, int sx, int sy, int planeWidth, int lumaHeight) {
    const int blockWidth = 32 >> sx;
    const int blockHeight = 32 >> sy;
    const int bx = x / blockWidth;
    const int by = y / blockHeight;
    const int lx = x - bx * blockWidth;
    const int ly = y - by * blockHeight;
    const int bw = min(blockWidth, planeWidth - bx * blockWidth);
    const int bh = (min(lumaHeight - by * 32, 32) + sy) >> sy;
    const int xStart = (g.overlap != 0 && bx > 0) ? min(2 >> sx, bw) : 0;
    const int yStart = (g.overlap != 0 && by > 0) ? min(2 >> sy, bh) : 0;
    const int centre = 128 << (g.bitDepth - 8);
    const int low = -centre;
    const int high = centre - 1;

    const int current = grainTemplate(lut, offsets, g.blockColumns, bx, by, 0, 0, lx, ly, sx, sy);
    const bool inColumn = lx < xStart;
    const bool inRow = ly < yStart;
    if (!inColumn && !inRow) { return current; }
    const int columnOld = sx != 0 ? 23 : (lx == 0 ? 27 : 17);
    const int columnNew = sx != 0 ? 22 : (lx == 0 ? 17 : 27);
    const int rowOld = sy != 0 ? 23 : (ly == 0 ? 27 : 17);
    const int rowNew = sy != 0 ? 22 : (ly == 0 ? 17 : 27);
    if (!inRow) {
        const int left = grainTemplate(lut, offsets, g.blockColumns, bx, by, 1, 0, lx, ly, sx, sy);
        return blendGrain(left, current, columnOld, columnNew, low, high);
    }
    const int top = grainTemplate(lut, offsets, g.blockColumns, bx, by, 0, 1, lx, ly, sx, sy);
    if (!inColumn) {
        return blendGrain(top, current, rowOld, rowNew, low, high);
    }
    const int topLeft = grainTemplate(lut, offsets, g.blockColumns, bx, by, 1, 1, lx, ly, sx, sy);
    const int left = grainTemplate(lut, offsets, g.blockColumns, bx, by, 1, 0, lx, ly, sx, sy);
    const int topBlend = blendGrain(topLeft, top, columnOld, columnNew, low, high);
    const int sideBlend = blendGrain(left, current, columnOld, columnNew, low, high);
    return blendGrain(topBlend, sideBlend, rowOld, rowNew, low, high);
}

static inline int grainedLuma(int raw, int x, int y, constant LagoonFilmGrainParameters &g,
                              LagoonFilmGrainTables t, int width, int height) {
    const int grain = grainAt(t.luma, t.offsets, g, x, y, 0, 0, width, height);
    const int noise = grainRound2(int(t.scaling[raw]) * grain, g.scalingShift);
    const int depthShift = g.bitDepth - 8;
    const int low = g.restrictedRange != 0 ? 16 << depthShift : 0;
    const int high = g.restrictedRange != 0 ? 235 << depthShift : (1 << g.bitDepth) - 1;
    return clamp(raw + noise, low, high);
}

// `averageLuma` is the source luma under the sample, before grain.
static inline int grainedChroma(int raw, int averageLuma, int x, int y, bool isCr, int sx, int sy,
                                constant LagoonFilmGrainParameters &g, LagoonFilmGrainTables t,
                                int width, int height) {
    const int depthShift = g.bitDepth - 8;
    const int maximum = (1 << g.bitDepth) - 1;
    int index = averageLuma;
    if (g.chromaFromLuma == 0) {
        const int combined = averageLuma * (isCr ? g.crLumaMult : g.cbLumaMult) + raw * (isCr ? g.crMult : g.cbMult);
        index = clamp((combined >> 6) + (isCr ? g.crOffset : g.cbOffset) * (1 << depthShift), 0, maximum);
    }
    const uint table = g.chromaFromLuma != 0 ? 0 : (isCr ? 2 : 1);
    const int planeWidth = (width + sx) >> sx;
    const int grain = grainAt(isCr ? t.cr : t.cb, t.offsets, g, x, y, sx, sy, planeWidth, height);
    const int noise = grainRound2(int(t.scaling[table * g.scalingSize + uint(index)]) * grain, g.scalingShift);
    const int low = g.restrictedRange != 0 ? 16 << depthShift : 0;
    const int high = g.restrictedRange != 0 ? (g.identityMatrix != 0 ? 235 : 240) << depthShift : maximum;
    return clamp(raw + noise, low, high);
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
    constant LagoonFilmGrainParameters &grain [[buffer(2)]],
    device const short *lumaGrain [[buffer(3)]],
    device const short *cbGrain [[buffer(4)]],
    device const short *crGrain [[buffer(5)]],
    device const uchar *grainScaling [[buffer(6)]],
    device const uchar *grainOffsets [[buffer(7)]],
    texture2d<float, access::write> outputLuma [[texture(0)]],
    texture2d<float, access::write> outputChroma [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    const uint x = gid.x * 2;
    const uint y = gid.y * 2;
    if (x >= p.width || y >= p.height) { return; }
    const LagoonFilmGrainTables tables = { lumaGrain, cbGrain, crGrain, grainScaling, grainOffsets };
    const int width = int(p.width);
    const int height = int(p.height);

    uint lumaCodes[4];
    for (uint i = 0; i < 4; i++) {
        const uint sampleX = x + (i & 1);
        const uint sampleY = y + (i >> 1);
        int raw = rawSample(source, p.lumaOffset + sampleY * p.lumaStride + sampleX, p.sourceDepth);
        if (grain.applyLuma != 0) {
            raw = grainedLuma(raw, int(sampleX), int(sampleY), grain, tables, width, height);
        }
        lumaCodes[i] = codeFromRaw(raw, p.sourceDepth);
    }
    // The chroma samples under this block: one in 4:2:0, two stacked in
    // 4:2:2, four in 4:4:4, averaged.
    const uint spanX = 2u >> p.chromaShiftX;
    const uint spanY = 2u >> p.chromaShiftY;
    const int sx = int(p.chromaShiftX);
    const int sy = int(p.chromaShiftY);
    uint cbSum = 0;
    uint crSum = 0;
    for (uint dy = 0; dy < spanY; dy++) {
        for (uint dx = 0; dx < spanX; dx++) {
            const uint chromaX = gid.x * spanX + dx;
            const uint chromaY = gid.y * spanY + dy;
            const uint index = chromaY * p.chromaStride + chromaX;
            int cbRaw = rawSample(source, p.cbOffset + index, p.sourceDepth);
            int crRaw = rawSample(source, p.crOffset + index, p.sourceDepth);
            if (grain.applyCb != 0 || grain.applyCr != 0) {
                const uint lumaX = chromaX << p.chromaShiftX;
                const uint lumaRow = p.lumaOffset + (chromaY << p.chromaShiftY) * p.lumaStride;
                int average = rawSample(source, lumaRow + lumaX, p.sourceDepth);
                if (sx != 0) {
                    const uint nextX = min(lumaX + 1, p.width - 1);
                    average = (average + rawSample(source, lumaRow + nextX, p.sourceDepth) + 1) >> 1;
                }
                if (grain.applyCb != 0) {
                    cbRaw = grainedChroma(cbRaw, average, int(chromaX), int(chromaY), false, sx, sy, grain, tables, width, height);
                }
                if (grain.applyCr != 0) {
                    crRaw = grainedChroma(crRaw, average, int(chromaX), int(chromaY), true, sx, sy, grain, tables, width, height);
                }
            }
            cbSum += codeFromRaw(cbRaw, p.sourceDepth);
            crSum += codeFromRaw(crRaw, p.sourceDepth);
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
