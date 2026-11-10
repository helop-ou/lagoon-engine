import CoreVideo
import Foundation
import Metal

/// A premultiplied BGRA bitmap to blend at a place in the frame, in luma
/// pixels from the top left. Origin and size are even, so each piece covers
/// whole chroma samples.
nonisolated struct SubtitleOverlayPiece: @unchecked Sendable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int
    /// `width * 4` bytes per row, top row first.
    let pixels: Data
}

/// Everything to draw on the frames from one subtitle state. `revision`
/// changes with the content, so unchanged pieces stay uploaded.
nonisolated struct SubtitleOverlay: Sendable {
    let revision: Int
    let pieces: [SubtitleOverlayPiece]

    static let empty = SubtitleOverlay(revision: 0, pieces: [])
}

/// Burns subtitle pieces into decoded 4:2:0 frames in place, on the GPU.
///
/// Picture in Picture shows only the display layer, so the host's overlay
/// is gone there. Only the pieces' rectangles are touched, and only while
/// the engine asks for it.
nonisolated final class SubtitleFrameCompositor: @unchecked Sendable {
    /// Mirrors `LagoonSubtitleBlendParameters` in the shader, field for field.
    private struct Parameters {
        var originX: UInt32
        var originY: UInt32
        var width: UInt32
        var height: UInt32
        var fullRange: UInt32
        var depth: UInt32
        var transfer: UInt32
        var matrix: UInt32
        var whiteNits: Float
    }

    enum Transfer: UInt32 {
        case sdr = 0
        case pq = 1
        case hlg = 2
    }

    /// BT.2408 reference white. Subtitles at the grade's peak would glare.
    static let hdrWhiteNits: Float = 203
    /// HLG scene light that its OETF takes to 75%, the BT.2408 reference
    /// white level.
    static let hlgWhiteSceneLight: Float = 0.265

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let textureCache: CVMetalTextureCache
    /// Called on one queue at a time (the engine's pump).
    private var uploadedRevision: Int?
    private var uploaded: [(piece: SubtitleOverlayPiece, texture: MTLTexture)] = []

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue(),
              let library = try? device.makeDefaultLibrary(bundle: .module),
              let function = library.makeFunction(name: "lagoonBlendSubtitle"),
              let pipeline = try? device.makeComputePipelineState(function: function) else { return nil }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else { return nil }
        self.device = device
        self.commandQueue = commandQueue
        self.pipeline = pipeline
        textureCache = cache
    }

    /// The 4:2:0 bi-planar formats decoders hand the renderer: 8 or 10 bit,
    /// video or full range. Nil for anything else, which is left alone.
    static func planeFormat(of pixelFormat: OSType) -> (depth: Int, fullRange: Bool)? {
        switch pixelFormat {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: (8, false)
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: (8, true)
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange: (10, false)
        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange: (10, true)
        default: nil
        }
    }

    static func transfer(of buffer: CVBuffer) -> Transfer {
        let function = CVBufferCopyAttachment(buffer, kCVImageBufferTransferFunctionKey, nil) as? String
        if function == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String { return .pq }
        if function == kCVImageBufferTransferFunction_ITU_R_2100_HLG as String { return .hlg }
        return .sdr
    }

    static func matrix(of buffer: CVBuffer) -> UInt32 {
        let matrix = CVBufferCopyAttachment(buffer, kCVImageBufferYCbCrMatrixKey, nil) as? String
        if matrix == kCVImageBufferYCbCrMatrix_ITU_R_2020 as String { return 1 }
        if matrix == kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String
            || matrix == kCVImageBufferYCbCrMatrix_SMPTE_240M_1995 as String { return 2 }
        return 0
    }

    /// Blends and waits, so the frame is whole before the renderer sees it.
    /// False when the frame's format is not one this handles.
    @discardableResult
    func composite(_ overlay: SubtitleOverlay, into pixelBuffer: CVPixelBuffer) -> Bool {
        guard !overlay.pieces.isEmpty,
              let format = Self.planeFormat(of: CVPixelBufferGetPixelFormatType(pixelBuffer)) else { return false }
        let transfer = Self.transfer(of: pixelBuffer)
        let depth10 = format.depth == 10
        // The Core Video textures must outlive the GPU work, so they are held
        // here until the wait below returns.
        guard let lumaIn = texture(pixelBuffer, plane: 0, format: depth10 ? .r16Unorm : .r8Unorm),
              let lumaOut = texture(pixelBuffer, plane: 0, format: depth10 ? .r16Unorm : .r8Unorm),
              let chromaIn = texture(pixelBuffer, plane: 1, format: depth10 ? .rg16Unorm : .rg8Unorm),
              let chromaOut = texture(pixelBuffer, plane: 1, format: depth10 ? .rg16Unorm : .rg8Unorm),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return false }
        upload(overlay)
        let frameWidth = CVPixelBufferGetWidth(pixelBuffer)
        let frameHeight = CVPixelBufferGetHeight(pixelBuffer)
        var dispatched = 0
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(CVMetalTextureGetTexture(lumaIn), index: 0)
        encoder.setTexture(CVMetalTextureGetTexture(lumaOut), index: 1)
        encoder.setTexture(CVMetalTextureGetTexture(chromaIn), index: 2)
        encoder.setTexture(CVMetalTextureGetTexture(chromaOut), index: 3)
        for (piece, pieceTexture) in uploaded {
            guard let clipped = Self.clipped(piece, frameWidth: frameWidth, frameHeight: frameHeight) else { continue }
            dispatched += 1
            var parameters = Parameters(
                originX: UInt32(clipped.x),
                originY: UInt32(clipped.y),
                width: UInt32(clipped.width),
                height: UInt32(clipped.height),
                fullRange: format.fullRange ? 1 : 0,
                depth: UInt32(format.depth),
                transfer: transfer.rawValue,
                matrix: transfer == .sdr ? Self.matrix(of: pixelBuffer) : 1,
                whiteNits: transfer == .hlg ? Self.hlgWhiteSceneLight : Self.hdrWhiteNits
            )
            encoder.setTexture(pieceTexture, index: 4)
            encoder.setBytes(&parameters, length: MemoryLayout<Parameters>.stride, index: 0)
            let threads = MTLSize(width: 8, height: 8, depth: 1)
            let groups = MTLSize(
                width: (clipped.width / 2 + threads.width - 1) / threads.width,
                height: (clipped.height / 2 + threads.height - 1) / threads.height,
                depth: 1
            )
            encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threads)
        }
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        withExtendedLifetime((lumaIn, lumaOut, chromaIn, chromaOut)) {}
        return commandBuffer.status == .completed && dispatched > 0
    }

    private func upload(_ overlay: SubtitleOverlay) {
        guard uploadedRevision != overlay.revision else { return }
        uploaded = overlay.pieces.compactMap { piece in texture(for: piece).map { (piece, $0) } }
        uploadedRevision = overlay.revision
    }

    /// The part of a piece inside the frame. The kernel reads the piece
    /// from its top left, so only the far edges are trimmed.
    static func clipped(_ piece: SubtitleOverlayPiece, frameWidth: Int, frameHeight: Int) -> SubtitleOverlayPiece? {
        guard piece.x >= 0, piece.y >= 0, piece.x % 2 == 0, piece.y % 2 == 0 else { return nil }
        let width = min(piece.width, frameWidth - piece.x) & ~1
        let height = min(piece.height, frameHeight - piece.y) & ~1
        guard width > 0, height > 0 else { return nil }
        return SubtitleOverlayPiece(x: piece.x, y: piece.y, width: width, height: height, pixels: piece.pixels)
    }

    private func texture(_ pixelBuffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat) -> CVMetalTexture? {
        var texture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil, format,
            CVPixelBufferGetWidthOfPlane(pixelBuffer, plane),
            CVPixelBufferGetHeightOfPlane(pixelBuffer, plane),
            plane, &texture
        )
        guard status == kCVReturnSuccess, let texture, CVMetalTextureGetTexture(texture) != nil else { return nil }
        return texture
    }

    private func texture(for piece: SubtitleOverlayPiece) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: piece.width,
            height: piece.height,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        guard piece.pixels.count >= piece.width * piece.height * 4,
              let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        piece.pixels.withUnsafeBytes { bytes in
            texture.replace(
                region: MTLRegionMake2D(0, 0, piece.width, piece.height),
                mipmapLevel: 0,
                withBytes: bytes.baseAddress!,
                bytesPerRow: piece.width * 4
            )
        }
        return texture
    }
}
