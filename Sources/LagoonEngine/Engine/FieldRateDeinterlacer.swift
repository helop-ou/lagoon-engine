import CoreMedia
import Foundation
import Libavutil
import Metal

/// Deinterlaces at field rate on the GPU: every interlaced frame becomes two
/// progressive pictures, one per field, half a frame apart.
///
/// The spatial `Deinterlacer` keeps one picture per frame, so 50i plays at
/// 25 fps and motion loses half its moments. This shows each field, and
/// predicts the missing rows from the fields either side (see
/// `FieldDeinterlace.metal`), so it needs the next frame before it can show
/// the current one: one frame of delay.
///
/// Outputs are `AVFrame`s in the source's planar format over GPU-written
/// memory, so whatever the decoder does with a decoded frame next (the copy
/// into a pixel buffer, the 10-bit GPU stage, tone mapping) applies to them
/// unchanged. Runs on the decoder's queue.
nonisolated final class FieldRateDeinterlacer: @unchecked Sendable {
    /// Mirrors `LagoonFieldParameters` in the shader, field for field.
    struct Parameters {
        var width: UInt32
        var height: UInt32
        var stride: UInt32
        var offset: UInt32
        var keptParity: UInt32
        var secondField: UInt32
        var depth: UInt32
    }

    /// One progressive picture, owned by the caller (`av_frame_free`).
    struct Field {
        let frame: UnsafeMutablePointer<AVFrame>
        let timing: CMSampleTimingInfo
    }

    /// The planar formats taken: 8-bit and 10-bit 4:2:0.
    static func supports(_ format: AVPixelFormat) -> Bool {
        format == AV_PIX_FMT_YUV420P || format == AV_PIX_FMT_YUVJ420P || format == AV_PIX_FMT_YUV420P10LE
    }

    private struct Held {
        let buffer: MTLBuffer
        let interlaced: Bool
        let topFieldFirst: Bool
        let timing: CMSampleTimingInfo
    }

    let width: Int
    let height: Int
    private let format: AVPixelFormat
    private let depth: Int
    private let elementSize: Int
    /// Element offsets and strides of the three packed planes.
    private let planes: [(offset: Int, stride: Int, width: Int, height: Int)]
    private let frameBytes: Int
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private var previous: Held?
    private var current: Held?

    init?(width: Int, height: Int, format: AVPixelFormat) {
        guard Self.supports(format), width > 1, height > 1, width.isMultiple(of: 2), height.isMultiple(of: 2),
              let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue(),
              let library = try? device.makeDefaultLibrary(bundle: .module),
              let function = library.makeFunction(name: "lagoonDeinterlaceField"),
              let pipeline = try? device.makeComputePipelineState(function: function) else { return nil }
        self.width = width
        self.height = height
        self.format = format
        depth = format == AV_PIX_FMT_YUV420P10LE ? 10 : 8
        elementSize = depth > 8 ? 2 : 1
        // Rows padded to 64 elements, as libavcodec aligns its own.
        let lumaStride = (width + 63) & ~63
        let chromaStride = (width / 2 + 63) & ~63
        let chromaSize = chromaStride * (height / 2)
        planes = [
            (0, lumaStride, width, height),
            (lumaStride * height, chromaStride, width / 2, height / 2),
            (lumaStride * height + chromaSize, chromaStride, width / 2, height / 2),
        ]
        frameBytes = (lumaStride * height + 2 * chromaSize) * elementSize
        self.device = device
        self.commandQueue = commandQueue
        self.pipeline = pipeline
    }

    /// Takes a decoded frame and returns the fields now ready: none for the
    /// first frame, then two for the frame before. The caller still owns
    /// `frame`. A progressive frame in the stream is shown twice, so the
    /// rate never changes mid-stream.
    func push(_ frame: UnsafePointer<AVFrame>, timing: CMSampleTimingInfo) throws -> [Field] {
        let held = try upload(frame, timing: timing)
        defer {
            previous = current
            current = held
        }
        guard let current else { return [] }
        return try fields(of: current, previous: previous ?? current, next: held)
    }

    /// End of stream: the last frame's fields, with no next frame to look at.
    func drain() throws -> [Field] {
        defer { reset() }
        guard let current else { return [] }
        return try fields(of: current, previous: previous ?? current, next: current)
    }

    /// Seek or flush: what is held belongs to the old position.
    func reset() {
        previous = nil
        current = nil
    }

    // MARK: - Fields

    private func fields(of frame: Held, previous: Held, next: Held) throws -> [Field] {
        let (first, second) = Self.fieldTimings(frame.timing)
        guard frame.interlaced else {
            return [try wrap(frame.buffer, timing: first), try wrap(frame.buffer, timing: second)]
        }
        let firstParity: UInt32 = frame.topFieldFirst ? 0 : 1
        let shownFirst = try render(frame, previous: previous, next: next, keptParity: firstParity, secondField: false)
        let shownSecond = try render(frame, previous: previous, next: next, keptParity: 1 - firstParity, secondField: true)
        return [try wrap(shownFirst, timing: first), try wrap(shownSecond, timing: second)]
    }

    /// The frame's interval split in two, the first field at its start.
    static func fieldTimings(_ timing: CMSampleTimingInfo) -> (CMSampleTimingInfo, CMSampleTimingInfo) {
        let half = timing.duration.isNumeric
            ? CMTimeMultiplyByRatio(timing.duration, multiplier: 1, divisor: 2)
            : CMTime.invalid
        let first = CMSampleTimingInfo(
            duration: half,
            presentationTimeStamp: timing.presentationTimeStamp,
            decodeTimeStamp: .invalid
        )
        let secondStart = timing.presentationTimeStamp.isNumeric && half.isNumeric
            ? timing.presentationTimeStamp + half
            : CMTime.invalid
        let second = CMSampleTimingInfo(duration: half, presentationTimeStamp: secondStart, decodeTimeStamp: .invalid)
        return (first, second)
    }

    private func render(_ frame: Held, previous: Held, next: Held, keptParity: UInt32, secondField: Bool) throws -> MTLBuffer {
        let output = try buffer()
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw MetalFrameConverter.ConverterError.dispatch("no command buffer")
        }
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(previous.buffer, offset: 0, index: 0)
        encoder.setBuffer(frame.buffer, offset: 0, index: 1)
        encoder.setBuffer(next.buffer, offset: 0, index: 2)
        encoder.setBuffer(output, offset: 0, index: 3)
        for plane in planes {
            // Chroma rows of a 4:2:0 interlaced frame alternate fields too.
            var parameters = Parameters(
                width: UInt32(plane.width),
                height: UInt32(plane.height),
                stride: UInt32(plane.stride),
                offset: UInt32(plane.offset),
                keptParity: keptParity,
                secondField: secondField ? 1 : 0,
                depth: UInt32(depth)
            )
            encoder.setBytes(&parameters, length: MemoryLayout<Parameters>.stride, index: 4)
            encoder.dispatchThreads(
                MTLSize(width: plane.width, height: plane.height, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1)
            )
        }
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else {
            throw MetalFrameConverter.ConverterError.dispatch(commandBuffer.error?.localizedDescription ?? "GPU failed")
        }
        return output
    }

    // MARK: - Buffers

    private func upload(_ frame: UnsafePointer<AVFrame>, timing: CMSampleTimingInfo) throws -> Held {
        let destination = try buffer()
        let base = destination.contents()
        let data = [frame.pointee.data.0, frame.pointee.data.1, frame.pointee.data.2]
        let lineSizes = [frame.pointee.linesize.0, frame.pointee.linesize.1, frame.pointee.linesize.2]
        for (index, plane) in planes.enumerated() {
            guard let source = data[index] else { throw MetalFrameConverter.ConverterError.buffer }
            for row in 0..<plane.height {
                (base + (plane.offset + row * plane.stride) * elementSize).copyMemory(
                    from: source.advanced(by: row * Int(lineSizes[index])),
                    byteCount: plane.width * elementSize
                )
            }
        }
        let flags = frame.pointee.flags
        return Held(
            buffer: destination,
            interlaced: flags & Self.interlacedFlag != 0,
            topFieldFirst: flags & Self.topFieldFirstFlag != 0,
            timing: timing
        )
    }

    /// The buffer as a decoded frame, kept alive until the last reference to
    /// the frame is released. A buffer is never reused: the window and any
    /// number of output frames may hold the same one.
    private func wrap(_ buffer: MTLBuffer, timing: CMSampleTimingInfo) throws -> Field {
        guard let frame = av_frame_alloc() else { throw MetalFrameConverter.ConverterError.buffer }
        let retained = Unmanaged.passRetained(buffer as AnyObject).toOpaque()
        guard let reference = av_buffer_create(
            buffer.contents().assumingMemoryBound(to: UInt8.self),
            frameBytes,
            { opaque, _ in
                guard let opaque else { return }
                Unmanaged<AnyObject>.fromOpaque(opaque).release()
            },
            retained,
            Int32(AV_BUFFER_FLAG_READONLY)
        ) else {
            Unmanaged<AnyObject>.fromOpaque(retained).release()
            var pointer: UnsafeMutablePointer<AVFrame>? = frame
            av_frame_free(&pointer)
            throw MetalFrameConverter.ConverterError.buffer
        }
        frame.pointee.buf.0 = reference
        frame.pointee.format = format.rawValue
        frame.pointee.width = Int32(width)
        frame.pointee.height = Int32(height)
        let base = buffer.contents().assumingMemoryBound(to: UInt8.self)
        frame.pointee.data.0 = base + planes[0].offset * elementSize
        frame.pointee.data.1 = base + planes[1].offset * elementSize
        frame.pointee.data.2 = base + planes[2].offset * elementSize
        frame.pointee.linesize.0 = Int32(planes[0].stride * elementSize)
        frame.pointee.linesize.1 = Int32(planes[1].stride * elementSize)
        frame.pointee.linesize.2 = Int32(planes[2].stride * elementSize)
        return Field(frame: frame, timing: timing)
    }

    private func buffer() throws -> MTLBuffer {
        guard let made = device.makeBuffer(length: frameBytes, options: .storageModeShared) else {
            throw MetalFrameConverter.ConverterError.buffer
        }
        return made
    }

    /// libavutil declares these as macros, which do not reach Swift.
    private static let interlacedFlag: Int32 = 1 << 3
    private static let topFieldFirstFlag: Int32 = 1 << 4
}
