import CoreVideo
import Foundation
import Testing
@testable import LagoonEngine

/// The layouts VideoToolbox does not decode, written as 10-bit 4:2:0: each
/// code taken to 10 bits, chroma averaged over the samples under each 2x2
/// block. Runs on the simulator GPU via the copy path.
struct MetalFrameConverterLayoutTests {
    private static let width = 32
    private static let height = 16

    @Test(arguments: [
        (8, 1, 0), (10, 1, 0), (12, 1, 0),
        (8, 0, 0), (10, 0, 0), (12, 0, 0),
        (12, 1, 1),
    ])
    func aLayoutComesOutAsTenBit420(_ depth: Int, _ shiftX: Int, _ shiftY: Int) throws {
        let layout = MetalFrameConverter.SourceLayout(bitDepth: depth, chromaShiftX: shiftX, chromaShiftY: shiftY)
        let chromaWidth = Self.width >> shiftX
        let chromaHeight = Self.height >> shiftY
        let maximum = (1 << depth) - 1
        let luma = (0..<(Self.width * Self.height)).map { ($0 * 37) % (maximum + 1) }
        let cb = (0..<(chromaWidth * chromaHeight)).map { ($0 * 11 + 5) % (maximum + 1) }
        let cr = (0..<(chromaWidth * chromaHeight)).map { maximum - ($0 * 7) % (maximum + 1) }

        let output = try #require(try Self.convert(
            layout: layout, luma: luma, cb: cb, cr: cr, chromaWidth: chromaWidth, chromaHeight: chromaHeight
        ))

        var lumaMismatches = 0
        for y in 0..<Self.height {
            for x in 0..<Self.width where output.luma[y][x] != UInt16(Self.tenBit(luma[y * Self.width + x], depth)) << 6 {
                lumaMismatches += 1
            }
        }
        var chromaMismatches = 0
        let spanX = 2 >> shiftX
        let spanY = 2 >> shiftY
        for y in 0..<(Self.height / 2) {
            for x in 0..<(Self.width / 2) {
                var cbSum = 0
                var crSum = 0
                for dy in 0..<spanY {
                    for dx in 0..<spanX {
                        let index = (y * spanY + dy) * chromaWidth + x * spanX + dx
                        cbSum += Self.tenBit(cb[index], depth)
                        crSum += Self.tenBit(cr[index], depth)
                    }
                }
                let count = spanX * spanY
                if output.chroma[y][2 * x] != UInt16((cbSum + count / 2) / count) << 6
                    || output.chroma[y][2 * x + 1] != UInt16((crSum + count / 2) / count) << 6 {
                    chromaMismatches += 1
                }
            }
        }
        #expect(lumaMismatches == 0)
        #expect(chromaMismatches == 0)
    }

    /// The kernel's step to 10 bits.
    private static func tenBit(_ code: Int, _ depth: Int) -> Int {
        switch depth {
        case 8: code << 2
        case 12: min((code + 2) >> 2, 1023)
        default: min(code, 1023)
        }
    }

    private struct Output {
        let luma: [[UInt16]]
        let chroma: [[UInt16]]
    }

    private static func bytes(_ codes: [Int], depth: Int) -> [UInt8] {
        depth == 8
            ? codes.map { UInt8($0) }
            : codes.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
    }

    private static func convert(
        layout: MetalFrameConverter.SourceLayout,
        luma: [Int], cb: [Int], cr: [Int],
        chromaWidth: Int, chromaHeight: Int
    ) throws -> Output? {
        var configuration = MetalFrameConverter.Configuration(
            width: width, height: height, fullRange: false, toneMap: false,
            sourcePeakNits: 1000, targetPeakNits: 203, outputBitDepth: 10
        )
        configuration.source = layout
        let converter = try MetalFrameConverter(configuration: configuration)
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

        let elementSize = layout.bitDepth > 8 ? 2 : 1
        let lumaBytes = bytes(luma, depth: layout.bitDepth)
        let cbBytes = bytes(cb, depth: layout.bitDepth)
        let crBytes = bytes(cr, depth: layout.bitDepth)
        try lumaBytes.withUnsafeBytes { lumaPlane in
            try cbBytes.withUnsafeBytes { cbPlane in
                try crBytes.withUnsafeBytes { crPlane in
                    try converter.convert(
                        luma: .init(base: lumaPlane.baseAddress!, stride: width * elementSize, rows: height),
                        cb: .init(base: cbPlane.baseAddress!, stride: chromaWidth * elementSize, rows: chromaHeight),
                        cr: .init(base: crPlane.baseAddress!, stride: chromaWidth * elementSize, rows: chromaHeight),
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
