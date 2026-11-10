#include <metal_stdlib>
using namespace metal;

// One field of an interlaced frame as a whole progressive picture, for
// output at field rate: two pictures per frame, so motion keeps all fifty
// (or sixty) of its moments a second.
//
// Rows of the field being shown are copied. Each missing row is predicted
// spatially, along the edge direction that fits best, and that prediction is
// held inside the range the same row takes in the neighbouring fields of the
// other parity. Where those agree, nothing moved and the true row comes back;
// where they differ, the spatial guess stands. The approach is yadif's.
//
// One thread per sample of one plane. Planes are packed: `stride` elements a
// row, at `offset` in each buffer, the same in all three frames.
//
// Layout must match `FieldRateDeinterlacer.Parameters` field for field.
struct LagoonFieldParameters {
    uint width;
    uint height;
    uint stride;
    uint offset;
    uint keptParity;    // 0 shows the top field (even rows), 1 the bottom
    uint secondField;   // 1 when this field is the later of the frame's two
    uint depth;         // 8 reads bytes, 10 reads uint16 elements
};

static inline int sampleAt(device const uchar *frame, constant LagoonFieldParameters &p, int x, int y) {
    const int column = clamp(x, 0, int(p.width) - 1);
    const uint index = p.offset + uint(y) * p.stride + uint(column);
    if (p.depth == 8) { return int(frame[index]); }
    return int(((device const ushort *)frame)[index]);
}

// The nearest row of the given parity, inside the plane.
static inline int rowOfParity(int y, uint parity, int height) {
    int row = clamp(y, 0, height - 1);
    if (uint(row & 1) != parity) { row += row + 1 < height ? 1 : -1; }
    return clamp(row, 0, height - 1);
}

kernel void lagoonDeinterlaceField(
    device const uchar *previous [[buffer(0)]],
    device const uchar *current [[buffer(1)]],
    device const uchar *next [[buffer(2)]],
    device uchar *output [[buffer(3)]],
    constant LagoonFieldParameters &p [[buffer(4)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= p.width || gid.y >= p.height) { return; }
    const int x = int(gid.x);
    const int y = int(gid.y);
    const int height = int(p.height);
    int value;
    if (uint(y & 1) == p.keptParity || height < 2) {
        value = sampleAt(current, p, x, y);
    } else {
        // The other parity's fields either side of the one shown: the
        // previous frame's and this one's for the first field, this
        // frame's and the next one's for the second.
        device const uchar *before = p.secondField != 0 ? current : previous;
        device const uchar *after = p.secondField != 0 ? next : current;
        const int above = rowOfParity(y - 1, p.keptParity, height);
        const int below = rowOfParity(y + 1, p.keptParity, height);
        const int c = sampleAt(current, p, x, above);
        const int e = sampleAt(current, p, x, below);
        const int beforeHere = sampleAt(before, p, x, y);
        const int afterHere = sampleAt(after, p, x, y);
        const int temporal = (beforeHere + afterHere) >> 1;

        // How far this spot moves: across the missing row's own fields, and
        // in the shown field's rows against the frames either side.
        const int acrossFields = abs(beforeHere - afterHere) >> 1;
        const int againstPrevious = (abs(sampleAt(previous, p, x, above) - c) + abs(sampleAt(previous, p, x, below) - e)) >> 1;
        const int againstNext = (abs(sampleAt(next, p, x, above) - c) + abs(sampleAt(next, p, x, below) - e)) >> 1;
        int spread = max(acrossFields, max(againstPrevious, againstNext));

        // Edge-directed spatial guess: vertical first, then one and two
        // columns of slope each way, a direction tried further only if the
        // nearer one won.
        int spatial = (c + e) >> 1;
        int bestScore = abs(sampleAt(current, p, x - 1, above) - sampleAt(current, p, x - 1, below))
            + abs(c - e)
            + abs(sampleAt(current, p, x + 1, above) - sampleAt(current, p, x + 1, below)) - 1;
        for (int direction = -1; direction <= 1; direction += 2) {
            for (int step = 1; step <= 2; step++) {
                const int slope = direction * step;
                int score = 0;
                for (int k = -1; k <= 1; k++) {
                    score += abs(sampleAt(current, p, x + k + slope, above) - sampleAt(current, p, x + k - slope, below));
                }
                if (score >= bestScore) { break; }
                bestScore = score;
                spatial = (sampleAt(current, p, x + slope, above) + sampleAt(current, p, x - slope, below)) >> 1;
            }
        }

        // Widen the allowed range where the missing row is an extreme of
        // its neighbours two rows out, so thin lines are not flattened. Not
        // on the first or last row, whose one neighbour stands in for both
        // and would always look like an edge.
        if (above != below) {
            const int twoAbove = rowOfParity(y - 2, uint(y & 1), height);
            const int twoBelow = rowOfParity(y + 2, uint(y & 1), height);
            const int b = (sampleAt(before, p, x, twoAbove) + sampleAt(after, p, x, twoAbove)) >> 1;
            const int f = (sampleAt(before, p, x, twoBelow) + sampleAt(after, p, x, twoBelow)) >> 1;
            const int highest = max(max(temporal - e, temporal - c), min(b - c, f - e));
            const int lowest = min(min(temporal - e, temporal - c), max(b - c, f - e));
            spread = max(spread, max(lowest, -highest));
        }

        value = clamp(spatial, temporal - spread, temporal + spread);
    }
    const uint index = p.offset + gid.y * p.stride + gid.x;
    if (p.depth == 8) {
        output[index] = uchar(clamp(value, 0, 255));
    } else {
        ((device ushort *)output)[index] = ushort(clamp(value, 0, 1023));
    }
}
