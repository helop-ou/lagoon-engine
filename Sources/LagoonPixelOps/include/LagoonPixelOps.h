#ifndef LAGOON_PIXEL_OPS_H
#define LAGOON_PIXEL_OPS_H

#include <stddef.h>
#include <stdint.h>

void lagoon_interleave_420_chroma(
    const uint8_t *source_u,
    ptrdiff_t source_u_stride,
    const uint8_t *source_v,
    ptrdiff_t source_v_stride,
    uint8_t *destination,
    ptrdiff_t destination_stride,
    size_t width,
    size_t rows
);

/// Converts little-endian planar 10-bit samples (stored in the low bits) to
/// Core Video P010 samples (stored in the high bits). Strides are in bytes.
void lagoon_shift_10bit_plane_to_p010(
    const uint16_t *source,
    ptrdiff_t source_stride,
    uint16_t *destination,
    ptrdiff_t destination_stride,
    size_t width,
    size_t rows
);

/// Interleaves little-endian planar 10-bit U/V into Core Video's P010 UV
/// plane while shifting each component into the high bits. Strides are bytes.
void lagoon_interleave_420_chroma_10bit_to_p010(
    const uint16_t *source_u,
    ptrdiff_t source_u_stride,
    const uint16_t *source_v,
    ptrdiff_t source_v_stride,
    uint16_t *destination,
    ptrdiff_t destination_stride,
    size_t width,
    size_t rows
);

#endif
