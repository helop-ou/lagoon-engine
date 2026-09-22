#include "LagoonPixelOps.h"

#if defined(__ARM_NEON)
#include <arm_neon.h>
#endif

void lagoon_interleave_420_chroma(
    const uint8_t *source_u,
    ptrdiff_t source_u_stride,
    const uint8_t *source_v,
    ptrdiff_t source_v_stride,
    uint8_t *destination,
    ptrdiff_t destination_stride,
    size_t width,
    size_t rows
) {
    const size_t chroma_width = width / 2;
    for (size_t row = 0; row < rows; row++) {
        const uint8_t *u = source_u + (ptrdiff_t)row * source_u_stride;
        const uint8_t *v = source_v + (ptrdiff_t)row * source_v_stride;
        uint8_t *output = destination + (ptrdiff_t)row * destination_stride;
        size_t column = 0;

#if defined(__ARM_NEON)
        for (; column + 16 <= chroma_width; column += 16) {
            uint8x16x2_t uv;
            uv.val[0] = vld1q_u8(u + column);
            uv.val[1] = vld1q_u8(v + column);
            vst2q_u8(output + column * 2, uv);
        }
#endif

        for (; column < chroma_width; column++) {
            output[column * 2] = u[column];
            output[column * 2 + 1] = v[column];
        }
    }
}

void lagoon_shift_10bit_plane_to_p010(
    const uint16_t *source,
    ptrdiff_t source_stride,
    uint16_t *destination,
    ptrdiff_t destination_stride,
    size_t width,
    size_t rows
) {
    for (size_t row = 0; row < rows; row++) {
        const uint16_t *input = (const uint16_t *)((const uint8_t *)source + (ptrdiff_t)row * source_stride);
        uint16_t *output = (uint16_t *)((uint8_t *)destination + (ptrdiff_t)row * destination_stride);
        size_t column = 0;

#if defined(__ARM_NEON)
        for (; column + 8 <= width; column += 8) {
            uint16x8_t samples = vld1q_u16(input + column);
            vst1q_u16(output + column, vshlq_n_u16(samples, 6));
        }
#endif

        for (; column < width; column++) {
            output[column] = (uint16_t)(input[column] << 6);
        }
    }
}

void lagoon_interleave_420_chroma_10bit_to_p010(
    const uint16_t *source_u,
    ptrdiff_t source_u_stride,
    const uint16_t *source_v,
    ptrdiff_t source_v_stride,
    uint16_t *destination,
    ptrdiff_t destination_stride,
    size_t width,
    size_t rows
) {
    const size_t chroma_width = width / 2;
    for (size_t row = 0; row < rows; row++) {
        const uint16_t *u = (const uint16_t *)((const uint8_t *)source_u + (ptrdiff_t)row * source_u_stride);
        const uint16_t *v = (const uint16_t *)((const uint8_t *)source_v + (ptrdiff_t)row * source_v_stride);
        uint16_t *output = (uint16_t *)((uint8_t *)destination + (ptrdiff_t)row * destination_stride);
        size_t column = 0;

#if defined(__ARM_NEON)
        for (; column + 8 <= chroma_width; column += 8) {
            uint16x8x2_t uv;
            uv.val[0] = vshlq_n_u16(vld1q_u16(u + column), 6);
            uv.val[1] = vshlq_n_u16(vld1q_u16(v + column), 6);
            vst2q_u16(output + column * 2, uv);
        }
#endif

        for (; column < chroma_width; column++) {
            output[column * 2] = (uint16_t)(u[column] << 6);
            output[column * 2 + 1] = (uint16_t)(v[column] << 6);
        }
    }
}
