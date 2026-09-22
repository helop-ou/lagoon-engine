import LagoonPixelOps

/// SIMD pixel primitives. FFmpeg emits planar 4:2:0 but Core Video wants
/// NV12/P010, and doing the chroma zip in Swift used the software decoder's
/// whole real-time budget on Apple TV.
public enum LagoonPixelConversion {
    public static func interleave420Chroma(
        sourceU: UnsafePointer<UInt8>,
        sourceUStride: Int,
        sourceV: UnsafePointer<UInt8>,
        sourceVStride: Int,
        destination: UnsafeMutablePointer<UInt8>,
        destinationStride: Int,
        width: Int,
        rows: Int
    ) {
        lagoon_interleave_420_chroma(
            sourceU,
            sourceUStride,
            sourceV,
            sourceVStride,
            destination,
            destinationStride,
            width,
            rows
        )
    }

    public static func shift10BitPlaneToP010(
        source: UnsafePointer<UInt16>,
        sourceStride: Int,
        destination: UnsafeMutablePointer<UInt16>,
        destinationStride: Int,
        width: Int,
        rows: Int
    ) {
        lagoon_shift_10bit_plane_to_p010(
            source,
            sourceStride,
            destination,
            destinationStride,
            width,
            rows
        )
    }

    public static func interleave420Chroma10BitToP010(
        sourceU: UnsafePointer<UInt16>,
        sourceUStride: Int,
        sourceV: UnsafePointer<UInt16>,
        sourceVStride: Int,
        destination: UnsafeMutablePointer<UInt16>,
        destinationStride: Int,
        width: Int,
        rows: Int
    ) {
        lagoon_interleave_420_chroma_10bit_to_p010(
            sourceU,
            sourceUStride,
            sourceV,
            sourceVStride,
            destination,
            destinationStride,
            width,
            rows
        )
    }
}
