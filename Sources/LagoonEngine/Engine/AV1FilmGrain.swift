import Foundation
import Libavutil

/// AV1 film grain synthesis (AV1 specification 7.18.3), split so the GPU
/// does the per-pixel part.
///
/// dav1d applies grain on the CPU, about a tenth of a 4K decode, where
/// software AV1 has no room to spare. Here dav1d exports the parameters
/// instead, and this builds what every pixel needs from them: the grain
/// templates, the scaling tables and one random offset per 32x32 block. The
/// conversion kernel then adds the grain to each source sample. The result
/// must match dav1d's own output exactly, which `AV1FilmGrainTests` checks.
nonisolated struct AV1FilmGrain {
    static let templateWidth = 82
    static let templateHeight = 73
    static let blockSize = 32

    /// Mirrors `LagoonFilmGrainParameters` in the shader, field for field.
    struct Parameters: Equatable {
        var applyLuma: UInt32 = 0
        var applyCb: UInt32 = 0
        var applyCr: UInt32 = 0
        var chromaFromLuma: UInt32 = 0
        var overlap: UInt32 = 0
        var restrictedRange: UInt32 = 0
        var identityMatrix: UInt32 = 0
        var blockColumns: UInt32 = 0
        var scalingSize: UInt32 = 0
        var scalingShift: Int32 = 0
        var bitDepth: Int32 = 0
        var cbMult: Int32 = 0
        var crMult: Int32 = 0
        var cbLumaMult: Int32 = 0
        var crLumaMult: Int32 = 0
        var cbOffset: Int32 = 0
        var crOffset: Int32 = 0

        /// Grain the kernel skips entirely.
        static let none = Parameters()
    }

    /// What the parameters a stream signals hold, in the specification's
    /// terms. `AVFilmGrainAOMParams` already removes the bitstream offsets.
    struct Signal {
        var seed: UInt16
        var lumaPoints: [(value: UInt8, scaling: UInt8)]
        var cbPoints: [(value: UInt8, scaling: UInt8)]
        var crPoints: [(value: UInt8, scaling: UInt8)]
        var chromaScalingFromLuma: Bool
        var scalingShift: Int
        var arCoefficientLag: Int
        var arCoefficientsY: [Int]
        var arCoefficientsCb: [Int]
        var arCoefficientsCr: [Int]
        var arCoefficientShift: Int
        var grainScaleShift: Int
        var cbMult: Int
        var crMult: Int
        var cbLumaMult: Int
        var crLumaMult: Int
        var cbOffset: Int
        var crOffset: Int
        var overlap: Bool
        var restrictedRange: Bool
    }

    let parameters: Parameters
    /// 73 rows of 82, as are the chroma templates; a subsampled template
    /// uses its top left 38x44.
    let lumaGrain: [Int16]
    let cbGrain: [Int16]
    let crGrain: [Int16]
    /// Luma, Cb and Cr tables, `scalingSize` entries each.
    let scaling: [UInt8]
    /// One random byte per 32x32 luma block, `blockColumns` per row.
    let offsets: [UInt8]

    /// Nil when the frame carries no AV1 grain, or nothing to add.
    init?(frame: UnsafePointer<AVFrame>, bitDepth: Int, subX: Int, subY: Int) {
        guard let sideData = av_frame_get_side_data(frame, AV_FRAME_DATA_FILM_GRAIN_PARAMS),
              let data = sideData.pointee.data,
              Int(sideData.pointee.size) >= MemoryLayout<AVFilmGrainParams>.size else { return nil }
        let params = UnsafeRawPointer(data).assumingMemoryBound(to: AVFilmGrainParams.self)
        guard params.pointee.type == AV_FILM_GRAIN_PARAMS_AV1 else { return nil }
        self.init(
            signal: Self.signal(params),
            bitDepth: bitDepth,
            subX: subX,
            subY: subY,
            width: Int(frame.pointee.width),
            height: Int(frame.pointee.height),
            identityMatrix: frame.pointee.colorspace == AVCOL_SPC_RGB
        )
    }

    init?(signal: Signal, bitDepth: Int, subX: Int, subY: Int, width: Int, height: Int, identityMatrix: Bool) {
        let appliesLuma = !signal.lumaPoints.isEmpty
        let appliesCb = !signal.cbPoints.isEmpty || signal.chromaScalingFromLuma
        let appliesCr = !signal.crPoints.isEmpty || signal.chromaScalingFromLuma
        guard appliesLuma || appliesCb || appliesCr, width > 0, height > 0 else { return nil }

        let luma = Self.lumaTemplate(signal, bitDepth: bitDepth)
        cbGrain = Self.chromaTemplate(signal, luma: luma, isCr: false, bitDepth: bitDepth, subX: subX, subY: subY)
        crGrain = Self.chromaTemplate(signal, luma: luma, isCr: true, bitDepth: bitDepth, subX: subX, subY: subY)
        lumaGrain = luma

        let scalingSize = bitDepth > 8 ? 1 << bitDepth : 256
        scaling = Self.scalingTable(signal.lumaPoints, bitDepth: bitDepth)
            + Self.scalingTable(signal.cbPoints, bitDepth: bitDepth)
            + Self.scalingTable(signal.crPoints, bitDepth: bitDepth)

        let columns = (width + Self.blockSize - 1) / Self.blockSize
        let rows = (height + Self.blockSize - 1) / Self.blockSize
        offsets = Self.blockOffsets(seed: signal.seed, rows: rows, columns: columns)

        parameters = Parameters(
            applyLuma: appliesLuma ? 1 : 0,
            applyCb: appliesCb ? 1 : 0,
            applyCr: appliesCr ? 1 : 0,
            chromaFromLuma: signal.chromaScalingFromLuma ? 1 : 0,
            overlap: signal.overlap ? 1 : 0,
            restrictedRange: signal.restrictedRange ? 1 : 0,
            identityMatrix: identityMatrix ? 1 : 0,
            blockColumns: UInt32(columns),
            scalingSize: UInt32(scalingSize),
            scalingShift: Int32(signal.scalingShift),
            bitDepth: Int32(bitDepth),
            cbMult: Int32(signal.cbMult),
            crMult: Int32(signal.crMult),
            cbLumaMult: Int32(signal.cbLumaMult),
            crLumaMult: Int32(signal.crLumaMult),
            cbOffset: Int32(signal.cbOffset),
            crOffset: Int32(signal.crOffset)
        )
    }

    static func signal(_ params: UnsafePointer<AVFilmGrainParams>) -> Signal {
        var aom = params.pointee.codec.aom
        func points(_ count: Int32, _ pointer: UnsafeRawPointer) -> [(value: UInt8, scaling: UInt8)] {
            let pairs = pointer.assumingMemoryBound(to: UInt8.self)
            return (0..<Int(max(count, 0))).map { (pairs[$0 * 2], pairs[$0 * 2 + 1]) }
        }
        func coefficients<T>(_ tuple: inout T, count: Int) -> [Int] {
            withUnsafeBytes(of: &tuple) { bytes in
                (0..<count).map { Int(Int8(bitPattern: bytes[$0])) }
            }
        }
        let lag = Int(aom.ar_coeff_lag)
        let lumaCount = 2 * lag * (lag + 1)
        let luma = withUnsafeBytes(of: &aom.y_points) { points(aom.num_y_points, $0.baseAddress!) }
        let (cb, cr) = withUnsafeBytes(of: &aom.uv_points) { bytes in
            (points(aom.num_uv_points.0, bytes.baseAddress!),
             points(aom.num_uv_points.1, bytes.baseAddress!.advanced(by: 20)))
        }
        let (cbCoefficients, crCoefficients) = withUnsafeBytes(of: &aom.ar_coeffs_uv) { bytes in
            ((0..<(lumaCount + 1)).map { Int(Int8(bitPattern: bytes[$0])) },
             (0..<(lumaCount + 1)).map { Int(Int8(bitPattern: bytes[25 + $0])) })
        }
        return Signal(
            seed: UInt16(truncatingIfNeeded: params.pointee.seed),
            lumaPoints: luma,
            cbPoints: cb,
            crPoints: cr,
            chromaScalingFromLuma: aom.chroma_scaling_from_luma != 0,
            scalingShift: Int(aom.scaling_shift),
            arCoefficientLag: lag,
            arCoefficientsY: coefficients(&aom.ar_coeffs_y, count: lumaCount),
            arCoefficientsCb: cbCoefficients,
            arCoefficientsCr: crCoefficients,
            arCoefficientShift: Int(aom.ar_coeff_shift),
            grainScaleShift: Int(aom.grain_scale_shift),
            cbMult: Int(aom.uv_mult.0),
            crMult: Int(aom.uv_mult.1),
            cbLumaMult: Int(aom.uv_mult_luma.0),
            crLumaMult: Int(aom.uv_mult_luma.1),
            cbOffset: Int(aom.uv_offset.0),
            crOffset: Int(aom.uv_offset.1),
            overlap: aom.overlap_flag != 0,
            restrictedRange: aom.limit_output_range != 0
        )
    }

    // MARK: - The specification's processes

    /// The 16-bit linear feedback shift register of 7.18.3.2.
    struct RandomRegister {
        var state: UInt16

        mutating func next(bits: Int) -> Int {
            let r = Int(state)
            let bit = ((r >> 0) ^ (r >> 1) ^ (r >> 3) ^ (r >> 12)) & 1
            state = UInt16(truncatingIfNeeded: (r >> 1) | (bit << 15))
            return (Int(state) >> (16 - bits)) & ((1 << bits) - 1)
        }
    }

    static func round2(_ x: Int, _ shift: Int) -> Int {
        shift == 0 ? x : (x + (1 << (shift - 1))) >> shift
    }

    static func lumaTemplate(_ signal: Signal, bitDepth: Int) -> [Int16] {
        let (minimum, maximum) = grainRange(bitDepth: bitDepth)
        let shift = 12 - bitDepth + signal.grainScaleShift
        var random = RandomRegister(state: signal.seed)
        var grain = [Int](repeating: 0, count: templateWidth * templateHeight)
        for index in grain.indices {
            grain[index] = round2(Int(AV1GaussianSequence.values[random.next(bits: 11)]), shift)
        }
        let lag = signal.arCoefficientLag
        for y in 3..<templateHeight {
            for x in 3..<(templateWidth - 3) {
                var sum = 0
                var position = 0
                rows: for deltaRow in -lag...0 {
                    for deltaColumn in -lag...lag {
                        if deltaRow == 0 && deltaColumn == 0 { break rows }
                        sum += grain[(y + deltaRow) * templateWidth + x + deltaColumn] * signal.arCoefficientsY[position]
                        position += 1
                    }
                }
                let value = grain[y * templateWidth + x] + round2(sum, signal.arCoefficientShift)
                grain[y * templateWidth + x] = min(max(value, minimum), maximum)
            }
        }
        return grain.map { Int16($0) }
    }

    static func chromaTemplate(
        _ signal: Signal,
        luma: [Int16],
        isCr: Bool,
        bitDepth: Int,
        subX: Int,
        subY: Int
    ) -> [Int16] {
        let (minimum, maximum) = grainRange(bitDepth: bitDepth)
        let shift = 12 - bitDepth + signal.grainScaleShift
        let width = subX != 0 ? 44 : templateWidth
        let height = subY != 0 ? 38 : templateHeight
        var random = RandomRegister(state: signal.seed ^ (isCr ? 0x49d8 : 0xb524))
        var grain = [Int](repeating: 0, count: templateWidth * templateHeight)
        for y in 0..<height {
            for x in 0..<width {
                grain[y * templateWidth + x] = round2(Int(AV1GaussianSequence.values[random.next(bits: 11)]), shift)
            }
        }
        let coefficients = isCr ? signal.arCoefficientsCr : signal.arCoefficientsCb
        let lag = signal.arCoefficientLag
        for y in 3..<height {
            for x in 3..<(width - 3) {
                var sum = 0
                var position = 0
                rows: for deltaRow in -lag...0 {
                    for deltaColumn in -lag...lag {
                        if deltaRow == 0 && deltaColumn == 0 {
                            if !signal.lumaPoints.isEmpty {
                                var lumaSum = 0
                                let lumaX = ((x - 3) << subX) + 3
                                let lumaY = ((y - 3) << subY) + 3
                                for i in 0...subY {
                                    for j in 0...subX {
                                        lumaSum += Int(luma[(lumaY + i) * templateWidth + lumaX + j])
                                    }
                                }
                                sum += round2(lumaSum, subX + subY) * coefficients[position]
                            }
                            break rows
                        }
                        sum += grain[(y + deltaRow) * templateWidth + x + deltaColumn] * coefficients[position]
                        position += 1
                    }
                }
                let value = grain[y * templateWidth + x] + round2(sum, signal.arCoefficientShift)
                grain[y * templateWidth + x] = min(max(value, minimum), maximum)
            }
        }
        return grain.map { Int16($0) }
    }

    /// The piecewise-linear scaling function, one entry per sample value.
    /// Above 8 bits the 8-bit points are interpolated between, as dav1d
    /// does to match the specification's `scale_lut`.
    static func scalingTable(_ points: [(value: UInt8, scaling: UInt8)], bitDepth: Int) -> [UInt8] {
        let shiftX = bitDepth > 8 ? bitDepth - 8 : 0
        let size = 256 << shiftX
        guard let first = points.first, let last = points.last else { return [UInt8](repeating: 0, count: size) }
        var table = [Int](repeating: 0, count: size)
        for index in 0..<(Int(first.value) << shiftX) {
            table[index] = Int(first.scaling)
        }
        for i in 0..<(points.count - 1) {
            let startX = Int(points[i].value)
            let startY = Int(points[i].scaling)
            let deltaX = Int(points[i + 1].value) - startX
            let deltaY = Int(points[i + 1].scaling) - startY
            guard deltaX > 0 else { continue }
            let delta = deltaY * ((0x10000 + (deltaX >> 1)) / deltaX)
            var accumulated = 0x8000
            for x in 0..<deltaX {
                table[(startX + x) << shiftX] = startY + (accumulated >> 16)
                accumulated += delta
            }
        }
        for index in (Int(last.value) << shiftX)..<size {
            table[index] = Int(last.scaling)
        }
        if shiftX > 0 {
            let pad = 1 << shiftX
            for i in 0..<(points.count - 1) {
                let startX = Int(points[i].value) << shiftX
                let endX = Int(points[i + 1].value) << shiftX
                for x in stride(from: 0, to: endX - startX, by: pad) {
                    let range = table[startX + x + pad] - table[startX + x]
                    var accumulated = pad >> 1
                    for n in 1..<pad {
                        accumulated += range
                        table[startX + x + n] = table[startX + x] + (accumulated >> shiftX)
                    }
                }
            }
        }
        return table.map { UInt8(clamping: $0) }
    }

    /// One random byte per block: high nibble the template column offset,
    /// low nibble the row. Each 32-row stripe reseeds from its index.
    static func blockOffsets(seed: UInt16, rows: Int, columns: Int) -> [UInt8] {
        var offsets: [UInt8] = []
        offsets.reserveCapacity(rows * columns)
        for row in 0..<rows {
            var state = Int(seed)
            state ^= ((row * 37 + 178) & 0xFF) << 8
            state ^= (row * 173 + 105) & 0xFF
            var random = RandomRegister(state: UInt16(truncatingIfNeeded: state))
            for _ in 0..<columns {
                offsets.append(UInt8(random.next(bits: 8)))
            }
        }
        return offsets
    }

    private static func grainRange(bitDepth: Int) -> (Int, Int) {
        let centre = 128 << (bitDepth - 8)
        return (-centre, centre - 1)
    }
}
