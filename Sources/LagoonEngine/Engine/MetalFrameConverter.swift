import CoreVideo
import Foundation
import Metal

/// Turns a decoded 10-bit planar frame into a renderer-ready Core Video buffer
/// on the GPU.
///
/// On an Apple TV every core is spoken for by dav1d. The two CPU passes that
/// used to follow it — planar-to-P010 repack and VideoToolbox's PQ-to-SDR
/// transfer — measured ~0.5 of a core in-process and more outside it, which is
/// exactly the CPU the decoder was missing. One compute kernel does both in
/// about a millisecond of GPU time and no CPU time.
///
/// The source is read in place: FFmpeg's pool hands dav1d page-aligned
/// allocations whose three planes are one block, wrapped in a no-copy
/// `MTLBuffer` for one dispatch. Anything not page-aligned, or with separate
/// plane allocations, is copied into a staging buffer — slower, still cheaper
/// than either CPU pass.
nonisolated final class MetalFrameConverter: @unchecked Sendable {
    /// Mirrors `LagoonPlanarConvertParameters` in the shader, field for field.
    private struct Parameters {
        var width: UInt32
        var height: UInt32
        var lumaStride: UInt32
        var chromaStride: UInt32
        var lumaOffset: UInt32
        var cbOffset: UInt32
        var crOffset: UInt32
        var fullRange: UInt32
        var toneMap: UInt32
        var outputDepth: UInt32
        var sourcePeakNits: Float
        var targetPeakNits: Float
    }

    struct Configuration: Sendable {
        let width: Int
        let height: Int
        let fullRange: Bool
        /// PQ BT.2020 in, BT.709 SDR out. Off, the kernel only repacks.
        let toneMap: Bool
        /// Peak of the source grade, from its mastering metadata.
        let sourcePeakNits: Float
        /// What maps to SDR white. 203 nits is BT.2408's reference white.
        let targetPeakNits: Float
        /// 10 writes P010 texels, 8 writes NV12 texels.
        let outputBitDepth: Int
        /// Prints GPU-versus-wall timing every 120 frames.
        var verbose: Bool = false
    }

    enum ConverterError: LocalizedError {
        case noDevice
        case noKernel
        case texture(Int)
        case buffer
        case dispatch(String)

        var errorDescription: String? {
            switch self {
            case .noDevice: "Metal is unavailable"
            case .noKernel: "the conversion kernel is missing from the app's Metal library"
            case .texture(let status): "Metal could not address the destination buffer (\(status))"
            case .buffer: "Metal could not allocate a staging buffer"
            case .dispatch(let detail): "the GPU conversion failed (\(detail))"
            }
        }
    }

    struct Plane {
        let base: UnsafeRawPointer
        /// Bytes per row.
        let stride: Int
        let rows: Int
    }

    let configuration: Configuration
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let textureCache: CVMetalTextureCache
    private let pageSize = Int(getpagesize())
    /// Staging buffers for the copy path, one per frame in flight: a frame
    /// is copied while the previous one's kernel may still be reading.
    private let stagingLock = NSLock()
    private var freeStaging: [MTLBuffer] = []
    /// How many frames took the no-copy path, for the diagnostics line.
    private(set) var zeroCopyFrames = 0
    private(set) var copiedFrames = 0
    private let statisticsLock = NSLock()
    private var gpuSeconds = 0.0
    private var wallSeconds = 0.0
    private var mapSeconds = 0.0
    private var timedFrames = 0

    init(configuration: Configuration) throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw ConverterError.noDevice
        }
        guard let library = device.makeDefaultLibrary(),
              let function = library.makeFunction(name: "lagoonConvertPlanar10") else {
            throw ConverterError.noKernel
        }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else {
            throw ConverterError.noDevice
        }
        self.configuration = configuration
        self.device = device
        self.commandQueue = commandQueue
        pipeline = try device.makeComputePipelineState(function: function)
        textureCache = cache
    }

    /// Probes whether Metal can write to the pool's buffers, which is what
    /// decides between lossless-compressed and linear destinations at setup.
    func canWrite(_ pixelBuffer: CVPixelBuffer) -> Bool {
        (try? destinationTextures(for: pixelBuffer)) != nil
    }

    /// Runs the kernel and blocks until the GPU has finished, so the caller
    /// may release the source frame the moment this returns.
    func convert(luma: Plane, cb: Plane, cr: Plane, into destination: CVPixelBuffer) throws {
        let done = DispatchSemaphore(value: 0)
        // The semaphore is the ownership boundary: this thread owns `outcome`
        // until `convertAsync` returns, the completion thread owns it until it
        // signals, and this thread owns it again after `wait()`. The two
        // accesses can never overlap, which is what the compiler cannot see.
        nonisolated(unsafe) var outcome: Result<Void, Error> = .success(())
        try convertAsync(luma: luma, cb: cb, cr: cr, into: destination) { result in
            outcome = result
            done.signal()
        }
        done.wait()
        try outcome.get()
    }

    /// Submits the kernel and returns at once. `completion` runs on a Metal
    /// completion thread once the destination is fully written; the source
    /// planes must stay valid until then. One command queue does execute its
    /// command buffers in commit order, but Metal picks the thread each
    /// completed handler runs on and promises neither the order those calls
    /// are made in nor that one returns before the next begins — a caller that
    /// needs decode order imposes it itself (`GPUDeliverySequencer`).
    func convertAsync(
        luma: Plane,
        cb: Plane,
        cr: Plane,
        into destination: CVPixelBuffer,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) throws {
        let started = ProcessInfo.processInfo.systemUptime
        let source = try sourceBuffer(luma: luma, cb: cb, cr: cr)
        let mapped = ProcessInfo.processInfo.systemUptime
        // Both wrappers are made here and handed to the command buffer's
        // completion handler, which is the only other code that touches them
        // and only after the GPU is done. Neither Core Video type is Sendable
        // and neither needs to be: this is a hand-off, not sharing.
        nonisolated(unsafe) let (lumaTexture, chromaTexture) = try destinationTextures(for: destination)
        let elementSize = MemoryLayout<UInt16>.stride
        var parameters = Parameters(
            width: UInt32(configuration.width),
            height: UInt32(configuration.height),
            lumaStride: UInt32(luma.stride / elementSize),
            chromaStride: UInt32(cb.stride / elementSize),
            lumaOffset: UInt32(source.lumaOffset / elementSize),
            cbOffset: UInt32(source.cbOffset / elementSize),
            crOffset: UInt32(source.crOffset / elementSize),
            fullRange: configuration.fullRange ? 1 : 0,
            toneMap: configuration.toneMap ? 1 : 0,
            outputDepth: UInt32(configuration.outputBitDepth),
            sourcePeakNits: configuration.sourcePeakNits,
            targetPeakNits: configuration.targetPeakNits
        )
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw ConverterError.dispatch("no command buffer")
        }
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(source.buffer, offset: 0, index: 0)
        encoder.setBytes(&parameters, length: MemoryLayout<Parameters>.stride, index: 1)
        encoder.setTexture(CVMetalTextureGetTexture(lumaTexture), index: 0)
        encoder.setTexture(CVMetalTextureGetTexture(chromaTexture), index: 1)
        let grid = MTLSize(width: configuration.width / 2, height: configuration.height / 2, depth: 1)
        let threadWidth = pipeline.threadExecutionWidth
        let threadHeight = max(pipeline.maxTotalThreadsPerThreadgroup / threadWidth, 1)
        encoder.dispatchThreads(
            grid,
            threadsPerThreadgroup: MTLSize(width: threadWidth, height: threadHeight, depth: 1)
        )
        encoder.endEncoding()
        // The same hand-off for the source: the buffer is this dispatch's
        // alone — either a wrapper around the frame's pages or a staging
        // buffer taken out of the free list — and the completion handler is
        // where it is released or returned.
        nonisolated(unsafe) let sourceBufferHold = source.buffer
        commandBuffer.addCompletedHandler { [self] finished in
            // The texture wrappers hold the IOSurface and the no-copy buffer
            // holds the frame's pages; both must outlive the GPU's reads
            // and writes, and neither may outlive them by much.
            withExtendedLifetime((lumaTexture, chromaTexture, sourceBufferHold)) {}
            CVMetalTextureCacheFlush(textureCache, 0)
            if source.staged {
                stagingLock.withLock { freeStaging.append(sourceBufferHold) }
            }
            if configuration.verbose {
                statisticsLock.withLock {
                    gpuSeconds += finished.gpuEndTime - finished.gpuStartTime
                    wallSeconds += ProcessInfo.processInfo.systemUptime - started
                    mapSeconds += mapped - started
                    timedFrames += 1
                    if timedFrames % 120 == 0 {
                        let frames = Double(timedFrames)
                        print(String(
                            format: "MetalFrameConverter frames=%d gpuAvgMs=%.2f wallAvgMs=%.2f mapAvgMs=%.2f zeroCopy=%d copied=%d",
                            timedFrames, gpuSeconds / frames * 1000, wallSeconds / frames * 1000,
                            mapSeconds / frames * 1000, zeroCopyFrames, copiedFrames
                        ))
                    }
                }
            }
            if finished.status == .completed {
                completion(.success(()))
            } else {
                completion(.failure(ConverterError.dispatch(
                    finished.error?.localizedDescription ?? "GPU failed"
                )))
            }
        }
        commandBuffer.commit()
    }

    private func destinationTextures(for pixelBuffer: CVPixelBuffer) throws -> (CVMetalTexture, CVMetalTexture) {
        let depth10 = configuration.outputBitDepth == 10
        var luma: CVMetalTexture?
        let lumaStatus = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil,
            depth10 ? .r16Unorm : .r8Unorm,
            CVPixelBufferGetWidthOfPlane(pixelBuffer, 0),
            CVPixelBufferGetHeightOfPlane(pixelBuffer, 0),
            0, &luma
        )
        guard lumaStatus == kCVReturnSuccess, let luma else { throw ConverterError.texture(Int(lumaStatus)) }
        var chroma: CVMetalTexture?
        let chromaStatus = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil,
            depth10 ? .rg16Unorm : .rg8Unorm,
            CVPixelBufferGetWidthOfPlane(pixelBuffer, 1),
            CVPixelBufferGetHeightOfPlane(pixelBuffer, 1),
            1, &chroma
        )
        guard chromaStatus == kCVReturnSuccess, let chroma else { throw ConverterError.texture(Int(chromaStatus)) }
        return (luma, chroma)
    }

    private struct SourceBuffer {
        let buffer: MTLBuffer
        /// Byte offsets of each plane from the buffer's element zero.
        let lumaOffset: Int
        let cbOffset: Int
        let crOffset: Int
        /// True when `buffer` is a staging copy to return to the pool.
        let staged: Bool
    }

    /// FFmpeg lays a dav1d picture out for a height rounded up to this many
    /// rows, so each plane's region is that much taller than the rows the
    /// frame exposes (a 4K picture is allocated 3840x2176).
    private static let allocationRowAlignment = 128

    /// Whether the planes plausibly come from one allocation, which the
    /// no-copy path assumes: it wraps every byte from the first plane's page to
    /// the last plane's end, so an unmapped hole between them is a GPU fault.
    ///
    /// libdav1d's pooled pictures are one block but not a tight one — padding
    /// rows add ~150 KB to a 4K frame's span, so a bound of a page or two would
    /// reject every frame this stage exists for. VP9 Profile 2 reaches the same
    /// kernel through `avcodec_default_get_buffer2`, which pools one buffer per
    /// plane and spans heap this frame does not own. Allowing the padding rows
    /// plus a page per plane sits an order of magnitude above the first and far
    /// below the second.
    static func planesShareOneAllocation(_ planes: [Plane], pageSize: Int) -> Bool {
        guard let lowest = planes.map({ Int(bitPattern: $0.base) }).min(),
              let highest = planes.map({ Int(bitPattern: $0.base) + $0.stride * $0.rows }).max() else {
            return false
        }
        let occupied = planes.reduce(0) { $0 + $1.stride * $1.rows }
        let padding = planes.reduce(0) { $0 + $1.stride * allocationRowAlignment + pageSize }
        return highest - lowest <= occupied + padding
    }

    /// Wraps the frame's planes without copying when they are one page-aligned
    /// allocation, which FFmpeg's pooled large allocations are on Darwin;
    /// otherwise copies them into a staging buffer.
    private func sourceBuffer(luma: Plane, cb: Plane, cr: Plane) throws -> SourceBuffer {
        let planes = [luma, cb, cr]
        // The simulator's Metal driver backs no-copy buffers with XPC shared
        // memory and traps on ordinary malloc pages; only devices wrap, so the
        // whole branch is compiled out there instead of left unreachable
        // behind a constant `false`.
        #if !targetEnvironment(simulator)
        let lowest = planes.map { Int(bitPattern: $0.base) }.min()!
        let highest = planes.map { Int(bitPattern: $0.base) + $0.stride * $0.rows }.max()!
        let base = lowest & ~(pageSize - 1)
        let length = ((highest - base) + pageSize - 1) & ~(pageSize - 1)
        if base == lowest, Self.planesShareOneAllocation(planes, pageSize: pageSize),
           let buffer = device.makeBuffer(
               bytesNoCopy: UnsafeMutableRawPointer(bitPattern: base)!,
               length: length,
               options: .storageModeShared,
               deallocator: nil
           ) {
            zeroCopyFrames += 1
            return SourceBuffer(
                buffer: buffer,
                lumaOffset: Int(bitPattern: luma.base) - base,
                cbOffset: Int(bitPattern: cb.base) - base,
                crOffset: Int(bitPattern: cr.base) - base,
                staged: false
            )
        }
        #endif
        // Fallback: pack the three planes, keeping their strides, into a
        // staging buffer of this frame's own.
        let required = planes.reduce(0) { $0 + $1.stride * $1.rows }
        let reusable = stagingLock.withLock { () -> MTLBuffer? in
            guard let index = freeStaging.firstIndex(where: { $0.length >= required }) else { return nil }
            return freeStaging.remove(at: index)
        }
        guard let staging = reusable ?? device.makeBuffer(length: required, options: .storageModeShared) else {
            throw ConverterError.buffer
        }
        var offsets: [Int] = []
        var offset = 0
        for plane in planes {
            staging.contents().advanced(by: offset)
                .copyMemory(from: plane.base, byteCount: plane.stride * plane.rows)
            offsets.append(offset)
            offset += plane.stride * plane.rows
        }
        copiedFrames += 1
        return SourceBuffer(
            buffer: staging, lumaOffset: offsets[0], cbOffset: offsets[1], crOffset: offsets[2], staged: true
        )
    }
}
