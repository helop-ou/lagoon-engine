import CoreVideo
import Foundation
import Testing
@testable import LagoonEngine

/// Pins what the Metal output stage writes: an exact repack, and a tone map
/// that matches its spec for grey, keeps black black, reaches white at the
/// source peak, never inverts and stays neutral. Runs on the simulator GPU via
/// the copy path.
struct MetalFrameConverterTests {
    private static let width = 64
    private static let height = 32

    @Test func repackMovesTenBitCodesIntoTheHighBitsAndInterleavesChroma() throws {
        let frame = Self.patternFrame()
        let output = try #require(try Self.convert(frame, toneMap: false))
        var lumaMismatches = 0
        var chromaMismatches = 0
        for y in 0..<Self.height {
            for x in 0..<Self.width where output.luma[y][x] != frame.luma[y * Self.width + x] << 6 {
                lumaMismatches += 1
            }
        }
        let chromaWidth = Self.width / 2
        for y in 0..<(Self.height / 2) {
            for x in 0..<chromaWidth {
                let index = y * chromaWidth + x
                if output.chroma[y][2 * x] != frame.cb[index] << 6
                    || output.chroma[y][2 * x + 1] != frame.cr[index] << 6 {
                    chromaMismatches += 1
                }
            }
        }
        #expect(lumaMismatches == 0)
        #expect(chromaMismatches == 0)
    }

    @Test func toneMapMatchesItsReferenceForGreyAndNeverInverts() throws {
        // A limited-range PQ ramp down the rows, black to code 940, neutral
        // chroma.
        var frame = Self.PlanarFrame(
            luma: Array(repeating: 0, count: Self.width * Self.height),
            cb: Array(repeating: 512, count: Self.width * Self.height / 4),
            cr: Array(repeating: 512, count: Self.width * Self.height / 4)
        )
        var codes: [Int] = []
        for y in 0..<Self.height {
            let code = 64 + Int((Double(y) * 876.0 / Double(Self.height - 1)).rounded())
            codes.append(code)
            for x in 0..<Self.width {
                frame.luma[y * Self.width + x] = UInt16(code)
            }
        }
        let output = try #require(try Self.convert(frame, toneMap: true))
        let measured = (0..<Self.height).map { Int(output.luma[$0][Self.width / 2] >> 6) }

        #expect(measured[0] == 64, "black stays black")
        #expect(abs(measured[Self.height - 1] - 940) <= 2, "the source peak reaches SDR white")
        for y in 1..<Self.height {
            #expect(measured[y] >= measured[y - 1], "row \(y) inverted the ramp")
        }
        var worst = 0
        for y in 0..<Self.height {
            worst = max(worst, abs(measured[y] - Self.referenceSDRCode(limitedPQCode: codes[y])))
        }
        #expect(worst <= 2, "GPU tone map drifted \(worst) codes from its reference")

        var chromaDrift = 0
        for row in output.chroma {
            for sample in row {
                chromaDrift = max(chromaDrift, abs(Int(sample >> 6) - 512))
            }
        }
        #expect(chromaDrift <= 2, "grey picked up a tint of \(chromaDrift) codes")
    }

    // The no-copy wrap is compiled out of the simulator (its driver traps on
    // malloc pages), but the guard is testable. dav1d's pooled pictures are one
    // block; VP9 Profile 2 gets a buffer per plane from FFmpeg's default
    // allocator, and wrapping that span would hand the GPU unmapped heap.
    @Test func onlyPlanesFromOneAllocationMayBeWrappedWithoutCopying() {
        // A 4K 10-bit picture laid out like FFmpeg's dav1d output: 2160 visible
        // rows in regions allocated for 2176, one block with about 150 KB of
        // padding between planes.
        let pageSize = Int(getpagesize())
        let (width, height, allocatedHeight) = (3840, 2160, 2176)
        let (lumaStride, chromaStride) = (width * 2, width)
        let start = 0x2_0000_0000
        func plane(at address: Int, stride: Int, rows: Int) -> MetalFrameConverter.Plane {
            .init(base: UnsafeRawPointer(bitPattern: address)!, stride: stride, rows: rows)
        }
        let luma = plane(at: start, stride: lumaStride, rows: height)
        let cbStart = start + lumaStride * allocatedHeight
        let crStart = cbStart + chromaStride * (allocatedHeight / 2)

        let pooled = [
            luma,
            plane(at: cbStart, stride: chromaStride, rows: height / 2),
            plane(at: crStart, stride: chromaStride, rows: height / 2),
        ]
        #expect(MetalFrameConverter.planesShareOneAllocation(pooled, pageSize: pageSize))

        // A buffer per plane, as VP9 Profile 2 decodes into: the span crosses
        // heap this frame does not own, on both sides of luma.
        let perPlane = [
            luma,
            plane(at: start + 0x1000_0000, stride: chromaStride, rows: height / 2),
            plane(at: start - 0x1000_0000, stride: chromaStride, rows: height / 2),
        ]
        #expect(MetalFrameConverter.planesShareOneAllocation(perPlane, pageSize: pageSize) == false)
    }

    // MARK: - Reference

    /// The shader's arithmetic for a grey sample, in Double: BT.2020 Y'CbCr, PQ
    /// EOTF, BT.2390 EETF on luminance, 2020-to-709, 1/2.4 encoding, BT.709
    /// luma, limited-range code.
    private static func referenceSDRCode(limitedPQCode code: Int) -> Int {
        let sourcePeak = 1000.0
        let targetPeak = 203.0
        let yN = min(max((Double(code) - 64) / 876, 0), 1)
        let nits = pqToNits(yN)
        let luminance = nits * (0.2627 + 0.6780 + 0.0593)
        let peakSourcePQ = nitsToPQ(sourcePeak)
        let maxLum = nitsToPQ(targetPeak) / peakSourcePQ
        var e1 = min(nitsToPQ(luminance) / peakSourcePQ, 1)
        let ks = 1.5 * maxLum - 0.5
        if e1 > ks {
            let t = (e1 - ks) / (1 - ks)
            e1 = (2 * t * t * t - 3 * t * t + 1) * ks
                + (t * t * t - 2 * t * t + t) * (1 - ks)
                + (-2 * t * t * t + 3 * t * t) * maxLum
        }
        let mapped = pqToNits(e1 * peakSourcePQ)
        let scaled = luminance > 1e-4 ? nits * mapped / luminance : 0
        let rgb = [
            (1.6605 - 0.5876 - 0.0728) * scaled,
            (-0.1246 + 1.1329 - 0.0083) * scaled,
            (-0.0182 - 0.1006 + 1.1187) * scaled,
        ].map { min(max($0 / targetPeak, 0), 1) }
        let encoded = rgb.map { pow($0, 1 / 2.4) }
        let luma = 0.2126 * encoded[0] + 0.7152 * encoded[1] + 0.0722 * encoded[2]
        return Int((64 + 876 * luma).rounded())
    }

    private static func pqToNits(_ e: Double) -> Double {
        let m1 = 0.1593017578125, m2 = 78.84375
        let c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875
        let p = pow(max(e, 0), 1 / m2)
        return 10000 * pow(max(p - c1, 0) / max(c2 - c3 * p, 1e-6), 1 / m1)
    }

    private static func nitsToPQ(_ nits: Double) -> Double {
        let m1 = 0.1593017578125, m2 = 78.84375
        let c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875
        let y = pow(max(nits, 0) / 10000, m1)
        return pow((c1 + c2 * y) / (1 + c3 * y), m2)
    }

    // MARK: - Fixtures

    private struct PlanarFrame {
        var luma: [UInt16]
        var cb: [UInt16]
        var cr: [UInt16]
    }

    private struct Output {
        let luma: [[UInt16]]
        /// Interleaved Cb, Cr pairs per chroma row.
        let chroma: [[UInt16]]
    }

    private static func patternFrame() -> PlanarFrame {
        var frame = PlanarFrame(
            luma: Array(repeating: 0, count: width * height),
            cb: Array(repeating: 0, count: width * height / 4),
            cr: Array(repeating: 0, count: width * height / 4)
        )
        for y in 0..<height {
            for x in 0..<width {
                frame.luma[y * width + x] = UInt16((x * 13 + y * 7) % 1024)
            }
        }
        for y in 0..<(height / 2) {
            for x in 0..<(width / 2) {
                frame.cb[y * (width / 2) + x] = UInt16((x + y * 3) % 1024)
                frame.cr[y * (width / 2) + x] = UInt16(1023 - (x + y * 3) % 1024)
            }
        }
        return frame
    }

    private static func convert(_ frame: PlanarFrame, toneMap: Bool) throws -> Output? {
        let converter = try MetalFrameConverter(configuration: .init(
            width: width,
            height: height,
            fullRange: false,
            toneMap: toneMap,
            sourcePeakNits: 1000,
            targetPeakNits: 203,
            outputBitDepth: 10
        ))
        var destination: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            attributes as CFDictionary, &destination
        ) == kCVReturnSuccess, let destination else { return nil }

        var frame = frame
        try frame.luma.withUnsafeMutableBufferPointer { luma in
            try frame.cb.withUnsafeMutableBufferPointer { cb in
                try frame.cr.withUnsafeMutableBufferPointer { cr in
                    try converter.convert(
                        luma: .init(base: UnsafeRawPointer(luma.baseAddress!), stride: width * 2, rows: height),
                        cb: .init(base: UnsafeRawPointer(cb.baseAddress!), stride: width, rows: height / 2),
                        cr: .init(base: UnsafeRawPointer(cr.baseAddress!), stride: width, rows: height / 2),
                        into: destination
                    )
                }
            }
        }

        CVPixelBufferLockBaseAddress(destination, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(destination, .readOnly) }
        func rows(plane: Int, samplesPerRow: Int, count: Int) -> [[UInt16]] {
            let base = CVPixelBufferGetBaseAddressOfPlane(destination, plane)!
            let stride = CVPixelBufferGetBytesPerRowOfPlane(destination, plane)
            return (0..<count).map { row in
                let pointer = base.advanced(by: row * stride).assumingMemoryBound(to: UInt16.self)
                return Array(UnsafeBufferPointer(start: pointer, count: samplesPerRow))
            }
        }
        return Output(
            luma: rows(plane: 0, samplesPerRow: width, count: height),
            chroma: rows(plane: 1, samplesPerRow: width, count: height / 2)
        )
    }
}
