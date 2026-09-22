import CoreVideo
import Foundation
import Metal

/// Turns a decoded 10-bit planar frame into a renderer-ready Core Video buffer
/// on the GPU.
///
/// dav1d needs every Apple TV core. The P010 repack and PQ-to-SDR transfer
/// cost ~0.5 of a core on the CPU; this kernel does both in ~1 ms of GPU time.
///
/// The source is read in place when its planes are one page-aligned block
/// (dav1d's pool), via a no-copy `MTLBuffer`. Otherwise it is copied into a
/// staging buffer.
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
        /// What maps to SDR white (BT.2408 reference white is 203 nits).
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
    /// Staging buffers for the copy path, one per frame in flight.
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

    public init(configuration: Configuration) throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw ConverterError.noDevice
        }
        // The shader is in this package's bundle, not the host's main bundle.
        // Getting it wrong only shows at runtime.
        guard let library = try? device.makeDefaultLibrary(bundle: .module),
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

    /// Whether Metal can write the pool's buffers; picks lossless-compressed
    /// or linear destinations at setup.
    func canWrite(_ pixelBuffer: CVPixelBuffer) -> Bool {
        (try? destinationTextures(for: pixelBuffer)) != nil
    }

    /// Runs the kernel and blocks until the GPU is done, so the caller may
    /// release the source frame on return.
    func convert(luma: Plane, cb: Plane, cr: Plane, into destination: CVPixelBuffer) throws {
        let done = DispatchSemaphore(value: 0)
        // The semaphore hands `outcome` to the completion thread and back;
        // accesses never overlap, which the compiler cannot see.
        nonisolated(unsafe) var outcome: Result<Void, Error> = .success(())
        try convertAsync(luma: luma, cb: cb, cr: cr, into: destination) { result in
            outcome = result
            done.signal()
        }
        done.wait()
        try outcome.get()
    }

    /// Submits the kernel and returns. `completion` runs on a Metal thread
    /// once the destination is written; the source planes must stay valid
    /// until then. Completions are not ordered: use `GPUDeliverySequencer`.
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
        // Handed off to the completion handler, not shared.
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
        // Also handed off: the completion handler releases or returns it.
        nonisolated(unsafe) let sourceBufferHold = source.buffer
        commandBuffer.addCompletedHandler { [self] finished in
            // Keep the IOSurface and frame pages alive until the GPU is done.
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

    /// FFmpeg pads a dav1d picture's height to this many rows (4K is
    /// allocated 3840x2176).
    private static let allocationRowAlignment = 128

    /// Whether the planes plausibly share one allocation. The no-copy path
    /// wraps everything from the first plane to the last, so a hole between
    /// them is a GPU fault.
    ///
    /// The bound allows dav1d's padding rows (~150 KB at 4K) plus a page per
    /// plane, and rejects VP9 Profile 2's separate per-plane buffers.
    static func planesShareOneAllocation(_ planes: [Plane], pageSize: Int) -> Bool {
        guard let lowest = planes.map({ Int(bitPattern: $0.base) }).min(),
              let highest = planes.map({ Int(bitPattern: $0.base) + $0.stride * $0.rows }).max() else {
            return false
        }
        let occupied = planes.reduce(0) { $0 + $1.stride * $1.rows }
        let padding = planes.reduce(0) { $0 + $1.stride * allocationRowAlignment + pageSize }
        return highest - lowest <= occupied + padding
    }

    /// Wraps the planes without copying when they are one page-aligned
    /// allocation; otherwise copies them into a staging buffer.
    private func sourceBuffer(luma: Plane, cb: Plane, cr: Plane) throws -> SourceBuffer {
        let planes = [luma, cb, cr]
        // The simulator's Metal driver traps on no-copy buffers over malloc
        // pages, so only devices wrap.
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
        // Fallback: copy the planes, strides kept, into a staging buffer.
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
