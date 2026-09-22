import Foundation
import Testing
@testable import LagoonEngine

/// A small UDF 2.50 image laid out like BD-ROM: a metadata partition holding
/// every file entry, embedded and non-embedded directories, and a stream split
/// across two physical extents. Built rather than recorded, so each structure
/// the reader must survive is spelled out.
private struct DiscImageFixture {
    static let sectorSize = 2_048
    static let sectors = 420
    static let partitionStart = 300
    /// Physical blocks holding the metadata file's contents.
    static let metadataStart = 10
    static let metadataBlocks = 8

    private(set) var bytes = [UInt8](repeating: 0, count: sectors * sectorSize)

    /// Physical partition block -> absolute sector.
    static func physical(_ block: Int) -> Int { partitionStart + block }
    /// Metadata partition block -> absolute sector.
    static func metadata(_ block: Int) -> Int { physical(metadataStart) + block }

    mutating func u8(_ value: UInt8, sector: Int, _ offset: Int) {
        bytes[sector * Self.sectorSize + offset] = value
    }

    mutating func u16(_ value: UInt16, sector: Int, _ offset: Int) {
        for byte in 0..<2 {
            u8(UInt8((value >> (8 * UInt16(byte))) & 0xFF), sector: sector, offset + byte)
        }
    }

    mutating func u32(_ value: UInt32, sector: Int, _ offset: Int) {
        for byte in 0..<4 {
            u8(UInt8((value >> (8 * UInt32(byte))) & 0xFF), sector: sector, offset + byte)
        }
    }

    mutating func write(_ data: [UInt8], sector: Int, _ offset: Int) {
        for (index, byte) in data.enumerated() {
            u8(byte, sector: sector, offset + index)
        }
    }

    mutating func string(_ text: String, sector: Int, _ offset: Int) {
        write(Array(text.utf8), sector: sector, offset)
    }

    /// A long allocation descriptor: length, block, partition reference.
    mutating func longAD(sector: Int, _ offset: Int, length: UInt32, block: UInt32, partition: UInt16) {
        u32(length, sector: sector, offset)
        u32(block, sector: sector, offset + 4)
        u16(partition, sector: sector, offset + 8)
    }

    /// A file entry with allocation descriptors of the given kind.
    /// `descriptorType` 0 is short, 1 is long, 3 is embedded content.
    mutating func fileEntry(
        sector: Int,
        descriptorType: UInt16,
        descriptors: [UInt8]
    ) {
        u16(261, sector: sector, 0)
        u16(descriptorType, sector: sector, 34)
        u32(0, sector: sector, 168)
        u32(UInt32(descriptors.count), sector: sector, 172)
        write(descriptors, sector: sector, 176)
    }

    /// One directory entry.
    static func identifier(name: String, block: UInt32, partition: UInt16, isDirectory: Bool) -> [UInt8] {
        var entry = [UInt8](repeating: 0, count: 38)
        // Tag 257, little-endian like everything else in the filesystem.
        entry.replaceSubrange(0..<2, with: withUnsafeBytes(of: UInt16(257).littleEndian, Array.init))
        entry[18] = isDirectory ? 0x02 : 0x00
        entry[19] = UInt8(name.utf8.count + 1)   // the compression byte counts
        // The child's ICB, a long_ad at offset 20.
        let blockBytes = withUnsafeBytes(of: block.littleEndian, Array.init)
        entry.replaceSubrange(24..<28, with: blockBytes)
        let partitionBytes = withUnsafeBytes(of: partition.littleEndian, Array.init)
        entry.replaceSubrange(28..<30, with: partitionBytes)
        entry += [8]              // 8-bit characters
        entry += Array(name.utf8)
        while entry.count % 4 != 0 {
            entry += [0]
        }
        return entry
    }

    static func short(length: UInt32, block: UInt32) -> [UInt8] {
        withUnsafeBytes(of: length.littleEndian, Array.init)
            + withUnsafeBytes(of: block.littleEndian, Array.init)
    }

    static func long(length: UInt32, block: UInt32, partition: UInt16) -> [UInt8] {
        withUnsafeBytes(of: length.littleEndian, Array.init)
            + withUnsafeBytes(of: block.littleEndian, Array.init)
            + withUnsafeBytes(of: partition.littleEndian, Array.init)
            + [UInt8](repeating: 0, count: 6)
    }
}

/// A fixture image's bytes, addressed the way a server serves them.
private final class InMemoryDiscSource: DiscImageSource {
    private let data: Data
    private let reportsLength: Bool
    private(set) var reads = 0
    private(set) var largestRead = 0
    private(set) var requestedBytes = 0

    init(_ bytes: [UInt8], reportsLength: Bool = true) {
        data = Data(bytes)
        self.reportsLength = reportsLength
    }

    var imageLength: Int64? { reportsLength ? Int64(data.count) : nil }

    func read(at offset: Int64, count: Int) throws -> Data {
        reads += 1
        largestRead = max(largestRead, count)
        requestedBytes += count
        guard count >= 0, count <= 65_536 else { throw DiscImageError.resourceLimit }
        guard offset >= 0, offset < Int64(data.count) else { return Data() }
        let start = Int(offset)
        return data[start..<min(start + count, data.count)]
    }
}

private func makePlaylist(items: [(clip: String, seconds: Double)]) -> [UInt8] {
    var bytes = Array("MPLS0200".utf8)
    bytes += [UInt8](repeating: 0, count: 50)
    let start = 58
    bytes.replaceSubrange(8..<12, with: withUnsafeBytes(of: UInt32(start).bigEndian, Array.init))
    // PlayList: length, reserved, item count, sub-path count.
    bytes += withUnsafeBytes(of: UInt32(0).bigEndian, Array.init)
    bytes += [0, 0]
    bytes += withUnsafeBytes(of: UInt16(items.count).bigEndian, Array.init)
    bytes += [0, 0]
    for item in items {
        var body = [UInt8]()
        body += Array(item.clip.utf8)
        body += Array("M2TS".utf8)
        body += [0, 0, 0]
        body += withUnsafeBytes(of: UInt32(0).bigEndian, Array.init)
        body += withUnsafeBytes(of: UInt32(item.seconds * 45_000).bigEndian, Array.init)
        bytes += withUnsafeBytes(of: UInt16(body.count).bigEndian, Array.init)
        bytes += body
    }
    bytes.replaceSubrange(start..<(start + 4), with: withUnsafeBytes(of: UInt32(bytes.count - start - 4).bigEndian, Array.init))
    return bytes
}

/// Sectors 360-361 and 370 stand in for a clip split across two extents.
private let clipExtentOne = 360
private let clipExtentTwo = 370

private func makeFixture(playlist: [UInt8]) -> [UInt8] {
    var image = DiscImageFixture()
    typealias F = DiscImageFixture

    // Anchor, then the volume descriptor sequence it points at.
    image.u16(2, sector: 256, 0)
    image.u32(UInt32(3 * F.sectorSize), sector: 256, 16)
    image.u32(260, sector: 256, 20)

    image.u16(5, sector: 260, 0)                      // partition descriptor
    image.u32(UInt32(F.partitionStart), sector: 260, 188)
    image.u32(UInt32(F.sectors - F.partitionStart), sector: 260, 192)

    image.u16(6, sector: 261, 0)                      // logical volume descriptor
    image.u32(UInt32(F.sectorSize), sector: 261, 212)
    image.longAD(sector: 261, 248, length: 2_048, block: 0, partition: 1)  // file set
    image.u32(70, sector: 261, 264)
    image.u32(2, sector: 261, 268)                    // two partition maps
    image.u8(1, sector: 261, 440)                     // map 0: physical
    image.u8(6, sector: 261, 441)
    image.u8(2, sector: 261, 446)                     // map 1: metadata
    image.u8(64, sector: 261, 447)
    image.string("*UDF Metadata Partition", sector: 261, 451)
    image.u32(0, sector: 261, 486)                    // metadata file at physical block 0

    image.u16(8, sector: 262, 0)                      // terminating descriptor

    // The metadata file itself, described in the physical partition.
    image.fileEntry(
        sector: F.physical(0),
        descriptorType: 0,
        descriptors: F.short(
            length: UInt32(F.metadataBlocks * F.sectorSize),
            block: UInt32(F.metadataStart)
        )
    )

    // File set descriptor, in the metadata partition, pointing at the root.
    image.u16(256, sector: F.metadata(0), 0)
    image.longAD(sector: F.metadata(0), 400, length: 2_048, block: 1, partition: 1)

    // Root directory: contents embedded in its own entry.
    image.fileEntry(
        sector: F.metadata(1),
        descriptorType: 3,
        descriptors: F.identifier(name: "BDMV", block: 2, partition: 1, isDirectory: true)
    )
    image.fileEntry(
        sector: F.metadata(2),
        descriptorType: 3,
        descriptors: F.identifier(name: "PLAYLIST", block: 3, partition: 1, isDirectory: true)
            + F.identifier(name: "STREAM", block: 4, partition: 1, isDirectory: true)
    )
    // PLAYLIST's contents live in the metadata partition, not inside its entry:
    // the indirection a naive reader gets wrong.
    image.fileEntry(
        sector: F.metadata(3),
        descriptorType: 0,
        descriptors: F.short(length: 2_048, block: 5)
    )
    image.fileEntry(
        sector: F.metadata(4),
        descriptorType: 3,
        descriptors: F.identifier(name: "00001.M2TS", block: 7, partition: 1, isDirectory: false)
    )
    image.write(
        F.identifier(name: "00001.MPLS", block: 6, partition: 1, isDirectory: false),
        sector: F.metadata(5),
        0
    )
    // The playlist's bytes are in the physical partition, via a long
    // descriptor.
    image.fileEntry(
        sector: F.metadata(6),
        descriptorType: 1,
        descriptors: F.long(length: UInt32(playlist.count), block: 50, partition: 0)
    )
    // The clip, fragmented 4 KiB + 2 KiB, so a per-file mapping is not enough.
    image.fileEntry(
        sector: F.metadata(7),
        descriptorType: 1,
        descriptors: F.long(length: 4_096, block: 60, partition: 0)
            + F.long(length: 2_048, block: 70, partition: 0)
    )

    image.write(playlist, sector: F.physical(50), 0)
    image.u8(0x47, sector: clipExtentOne, 4)
    image.u8(0x47, sector: clipExtentTwo, 4)
    return image.bytes
}


/// A DVD-shaped image: one physical partition, no metadata indirection, and
/// `VIDEO_TS` instead of `BDMV` (UDF 1.02).
private func makeDVDFixture() -> [UInt8] {
    var image = DiscImageFixture()
    typealias F = DiscImageFixture

    image.u16(2, sector: 256, 0)
    image.u32(UInt32(3 * F.sectorSize), sector: 256, 16)
    image.u32(260, sector: 256, 20)

    image.u16(5, sector: 260, 0)
    image.u32(UInt32(F.partitionStart), sector: 260, 188)
    image.u32(UInt32(F.sectors - F.partitionStart), sector: 260, 192)

    image.u16(6, sector: 261, 0)
    image.u32(UInt32(F.sectorSize), sector: 261, 212)
    image.longAD(sector: 261, 248, length: 2_048, block: 0, partition: 0)
    image.u32(6, sector: 261, 264)
    image.u32(1, sector: 261, 268)                    // one partition map
    image.u8(1, sector: 261, 440)                     // physical
    image.u8(6, sector: 261, 441)

    image.u16(8, sector: 262, 0)

    // File set, root, VIDEO_TS - all in the physical partition.
    image.u16(256, sector: F.physical(0), 0)
    image.longAD(sector: F.physical(0), 400, length: 2_048, block: 1, partition: 0)
    image.fileEntry(
        sector: F.physical(1),
        descriptorType: 3,
        descriptors: F.identifier(name: "VIDEO_TS", block: 2, partition: 0, isDirectory: true)
    )
    image.fileEntry(
        sector: F.physical(2),
        descriptorType: 3,
        descriptors: F.identifier(name: "VIDEO_TS.VOB", block: 3, partition: 0, isDirectory: false)
            + F.identifier(name: "VTS_01_0.VOB", block: 4, partition: 0, isDirectory: false)
            + F.identifier(name: "VTS_01_1.VOB", block: 5, partition: 0, isDirectory: false)
            + F.identifier(name: "VTS_01_2.VOB", block: 6, partition: 0, isDirectory: false)
            + F.identifier(name: "VTS_02_1.VOB", block: 7, partition: 0, isDirectory: false)
    )
    // The disc menu and the title set's own menu, neither of which is film.
    image.fileEntry(sector: F.physical(3), descriptorType: 0, descriptors: F.short(length: 4_096, block: 50))
    image.fileEntry(sector: F.physical(4), descriptorType: 0, descriptors: F.short(length: 4_096, block: 60))
    // Title set 1, the larger, in two parts and with the first fragmented.
    image.fileEntry(
        sector: F.physical(5),
        descriptorType: 0,
        descriptors: F.short(length: 4_096, block: 70) + F.short(length: 4_096, block: 80)
    )
    image.fileEntry(sector: F.physical(6), descriptorType: 0, descriptors: F.short(length: 4_096, block: 90))
    // Title set 2, smaller.
    image.fileEntry(sector: F.physical(7), descriptorType: 0, descriptors: F.short(length: 2_048, block: 100))
    return image.bytes
}

@Suite("Disc images")
struct DiscImageTests {
    @Test func hostileICBLengthsAreRejectedBeforeTheSourceIsCalled() throws {
        let source = InMemoryDiscSource(makeDVDFixture())
        let volume = try UDFVolume(source: source)
        let reads = source.reads
        for length: UInt32 in [65_537, 0x3fff_ffff, .max] {
            #expect(throws: DiscImageError.resourceLimit) {
                _ = try volume.entry(.init(block: 1, partition: 0, length: length))
            }
        }
        #expect(source.reads == reads)
    }

    @Test func physicalAndMetadataMappingsRejectUncoveredRanges() throws {
        let source = InMemoryDiscSource(makeFixture(playlist: makePlaylist(items: [("00001", 60)])))
        let volume = try UDFVolume(source: source)
        let reads = source.reads
        for icb in [
            UDFVolume.ICB(block: .max, partition: 0, length: 2048),
            UDFVolume.ICB(block: 8, partition: 1, length: 2048),
            UDFVolume.ICB(block: 1, partition: 99, length: 2048),
        ] {
            #expect(throws: DiscImageError.self) { _ = try volume.entry(icb) }
        }
        #expect(source.reads == reads)
    }

    @Test func truncatedReadsFailEvenWhenTheTransportDoesNotKnowTheLength() {
        let source = InMemoryDiscSource(Array(makeDVDFixture().prefix(256 * 2048 + 100)), reportsLength: false)
        #expect(throws: DiscImageError.self) { _ = try UDFVolume(source: source) }
        #expect(source.reads == 1)
    }

    @Test func fileExtentsCannotPointOutsideThePartitionOrImage() throws {
        var bytes = makeFixture(playlist: makePlaylist(items: [("00001", 60)]))
        overwrite32(&bytes, DiscImageFixture.metadata(7) * 2048 + 180, .max)
        let source = InMemoryDiscSource(bytes)
        let volume = try UDFVolume(source: source)
        #expect(throws: DiscImageError.self) {
            _ = try volume.contents(of: .init(block: 7, partition: 1, length: 2048))
        }
        #expect(source.largestRead == 2048)
    }

    @Test func allocationListsCannotExtendBeyondTheirDescriptor() throws {
        var bytes = makeDVDFixture()
        overwrite32(&bytes, DiscImageFixture.physical(1) * 2048 + 172, .max)
        let volume = try UDFVolume(source: InMemoryDiscSource(bytes))
        #expect(throws: DiscImageError.self) { _ = try volume.list(volume.root) }
    }

    @Test func allocationContinuationCyclesFailWithoutRepeatedReads() throws {
        var bytes = makeFixture(playlist: makePlaylist(items: [("00001", 60)]))
        let root = DiscImageFixture.metadata(1) * 2048
        bytes[root + 34] = 0
        overwrite32(&bytes, root + 172, 8)
        overwrite32(&bytes, root + 176, 0xc000_0800)
        overwrite32(&bytes, root + 180, 7)
        let continuation = DiscImageFixture.metadata(7) * 2048
        bytes[continuation] = 2
        bytes[continuation + 1] = 1 // allocation extent tag 258
        overwrite32(&bytes, continuation + 20, 8)
        overwrite32(&bytes, continuation + 24, 0xc000_0800)
        overwrite32(&bytes, continuation + 28, 7)
        let source = InMemoryDiscSource(bytes)
        let volume = try UDFVolume(source: source)
        let reads = source.reads
        #expect(throws: DiscImageError.self) { _ = try volume.contents(of: volume.root) }
        #expect(source.reads - reads == 2)
    }

    @Test func metadataLimitsRejectInsteadOfReturningPartialFiles() throws {
        let volume = try UDFVolume(source: InMemoryDiscSource(makeFixture(playlist: makePlaylist(items: [("00001", 60)]))))
        #expect(throws: DiscImageError.resourceLimit) { _ = try volume.data(of: volume.root, limit: 1) }
        #expect(throws: DiscImageError.resourceLimit) {
            _ = try volume.data(of: .init(block: 3, partition: 1, length: 2048), limit: 2047)
        }
    }

    @Test func theReadBudgetCoversTheWholeMount() {
        let source = InMemoryDiscSource(makeDVDFixture())
        #expect(throws: DiscImageError.resourceLimit) {
            _ = try UDFVolume(source: source, budget: DiscReadBudget(bytes: 8192, reads: 4))
        }
        #expect(source.reads <= 4)
        #expect(source.requestedBytes <= 8192)
    }

    @Test func cancellationStopsMountingAndTitleDetection() throws {
        let source = InMemoryDiscSource(makeDVDFixture())
        #expect(throws: CancellationError.self) {
            _ = try UDFVolume(source: source, budget: DiscReadBudget(isCancelled: { source.reads >= 2 }))
        }
        #expect(source.reads == 2)
        var cancelled = false
        let volume = try UDFVolume(source: InMemoryDiscSource(makeDVDFixture()),
                                   budget: DiscReadBudget(isCancelled: { cancelled }))
        cancelled = true
        #expect(throws: CancellationError.self) { _ = try DiscTitle.mainTitle(in: volume, runtimeSeconds: nil) }
    }

    @Test func playlistsRespectTheirSectionAndItemLengthsAndCancellation() {
        let valid = makePlaylist(items: [("00001", 60)])
        var shortItem = valid
        shortItem[68] = 0
        shortItem[69] = 1
        var shortSection = valid
        shortSection[61] = 6
        for bytes in [shortItem, shortSection, Array(valid.dropLast())] {
            #expect(throws: DiscImageError.self) {
                _ = try BlurayPlaylistParser.parse(Data(bytes), name: "fixture")
            }
        }
        #expect(throws: CancellationError.self) {
            _ = try BlurayPlaylistParser.parse(Data(valid), name: "fixture", budget: DiscReadBudget(isCancelled: { true }))
        }
    }

    @Test func checkedByteAndStreamArithmeticCannotTrapOnExtremeValues() {
        let bytes = DiscBytes(Data([1, 2, 3, 4]))
        #expect(throws: DiscImageError.self) { _ = try bytes.u16(Int.max) }
        #expect(throws: DiscImageError.self) { _ = try bytes.u32(Int.max) }
        #expect(throws: DiscImageError.self) { _ = try bytes.u64(Int.max) }
        #expect(throws: DiscImageError.self) { _ = try bytes.bytes(1, Int.max) }
        for extents in [
            [DiscExtent(offset: -1, length: 1)],
            [DiscExtent(offset: 0, length: -1)],
            [DiscExtent(offset: .max, length: 1)],
            [DiscExtent(offset: 0, length: .max), DiscExtent(offset: 0, length: 1)],
        ] {
            #expect(throws: DiscImageError.self) { _ = try DiscStreamMap(extents: extents) }
        }
    }

    @Test func mutatedDiscMetadataAlwaysStaysWithinItsReadBudget() {
        let fixture = makeFixture(playlist: makePlaylist(items: [("00001", 60)]))
        let positions = [256 * 2048 + 16, 256 * 2048 + 20, 260 * 2048 + 188,
                         260 * 2048 + 192, 261 * 2048 + 212, 261 * 2048 + 264,
                         261 * 2048 + 268, DiscImageFixture.metadata(1) * 2048 + 172,
                         DiscImageFixture.metadata(7) * 2048 + 176]
        var seed: UInt64 = 0x142
        for iteration in 0..<128 {
            seed = seed &* 6364136223846793005 &+ 1
            var bytes = fixture
            overwrite32(&bytes, positions[iteration % positions.count], UInt32(truncatingIfNeeded: seed >> 16))
            let source = InMemoryDiscSource(bytes, reportsLength: iteration % 2 == 0)
            do {
                let volume = try UDFVolume(source: source, budget: DiscReadBudget(bytes: 512 * 1024, reads: 128, operations: 4096))
                _ = try DiscTitle.mainTitle(in: volume, runtimeSeconds: nil)
            } catch is DiscImageError {
                // Declining mutated metadata is the intended fallback.
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
            #expect(source.largestRead <= 65_536)
            #expect(source.reads <= 128)
            #expect(source.requestedBytes <= 512 * 1024)
        }
    }

    private func overwrite32(_ bytes: inout [UInt8], _ offset: Int, _ value: UInt32) {
        bytes.replaceSubrange(offset..<(offset + 4), with: withUnsafeBytes(of: value.littleEndian, Array.init))
    }

    @Test func aUDFVolumeResolvesNamesThroughTheMetadataPartition() throws {
        // File entries live in the metadata file and their data outside it.
        // Resolving every extent in the entry's own partition finds empty
        // directories.
        let source = InMemoryDiscSource(makeFixture(playlist: makePlaylist(
            items: [("00001", 60), ("00001", 60)]
        )))
        let volume = try UDFVolume(source: source)

        let playlists = try #require(try volume.entry(at: "BDMV/PLAYLIST"))
        #expect(playlists.isDirectory)
        #expect(try volume.list(playlists.icb).map(\.name) == ["00001.MPLS"])

        let stream = try #require(try volume.entry(at: "BDMV/STREAM"))
        let clip = try #require(try volume.list(stream.icb).first)
        #expect(clip.name == "00001.M2TS")
        #expect(!clip.isDirectory)
    }

    @Test func aFragmentedClipKeepsBothOfItsExtents() throws {
        let source = InMemoryDiscSource(makeFixture(playlist: makePlaylist(
            items: [("00001", 60)]
        )))
        let volume = try UDFVolume(source: source)
        let clip = try #require(try volume.entry(at: "BDMV/STREAM/00001.M2TS"))

        guard case .extents(let extents) = try volume.contents(of: clip.icb) else {
            Issue.record("a stream should never be stored inside its file entry")
            return
        }
        let sector = Int64(DiscImageFixture.sectorSize)
        #expect(extents == [
            DiscExtent(offset: Int64(clipExtentOne) * sector, length: 4_096),
            DiscExtent(offset: Int64(clipExtentTwo) * sector, length: 2_048),
        ])
    }

    @Test func pathsAreCaseInsensitiveAndUnknownOnesAreNil() throws {
        let source = InMemoryDiscSource(makeFixture(playlist: makePlaylist(items: [("00001", 60)])))
        let volume = try UDFVolume(source: source)
        #expect(try volume.entry(at: "bdmv/playlist") != nil)
        #expect(try volume.entry(at: "BDMV/CLIPINF") == nil)
    }

    @Test func somethingThatIsNotAnImageIsDeclinedRatherThanGuessedAt() {
        // The anchor is at a fixed sector, so detection costs one read. A
        // non-disc must fail here, where the host can still ask for the media
        // another way.
        let source = InMemoryDiscSource([UInt8](repeating: 0, count: 600 * 2_048))
        #expect(throws: DiscImageError.notUDF) {
            _ = try UDFVolume(source: source)
        }
    }

    @Test func aTitleIsReadAsOneStreamAcrossItsExtents() throws {
        let source = InMemoryDiscSource(makeFixture(playlist: makePlaylist(
            items: [("00001", 60), ("00001", 30)]
        )))
        let volume = try UDFVolume(source: source)
        let title = try BlurayDisc.mainTitle(in: volume, runtimeSeconds: nil)

        #expect(title.playlist?.name == "00001.MPLS")
        // Two play items over one fragmented clip: four extents, in order.
        #expect(title.stream.extents.count == 4)
        #expect(title.stream.length == 2 * (4_096 + 2_048))
    }


    @Test func aDVDImageMountsWithoutTheMetadataPartitionBluRayNeeds() throws {
        let volume = try UDFVolume(source: InMemoryDiscSource(makeDVDFixture()))
        #expect(try volume.entry(at: "VIDEO_TS") != nil)
        #expect(try volume.entry(at: "BDMV") == nil)
        #expect(try DVDDisc.isDVD(volume))
        #expect(try !BlurayDisc.isBluray(volume))
    }

    @Test func aDVDTitleIsItsLargestTitleSetInOrder() throws {
        let volume = try UDFVolume(source: InMemoryDiscSource(makeDVDFixture()))
        let title = try DiscTitle.mainTitle(in: volume, runtimeSeconds: nil)
        // A DVD has no playlist to name.
        #expect(title.playlist == nil)
        // Title set 1 (12 KiB over two parts, the first fragmented) beats title
        // set 2; neither menu is included.
        #expect(title.stream.length == 12_288)
        let sector = Int64(DiscImageFixture.sectorSize)
        #expect(title.stream.extents.map(\.offset) == [70, 80, 90].map { Int64($0 + DiscImageFixture.partitionStart) * sector })
    }

    @Test func aMenuIsNeverMistakenForTheFilm() {
        // Part 0 is the title set's menu and VIDEO_TS.VOB is the disc's own.
        #expect(DVDDisc.titleSetPart(of: "VTS_01_1.VOB")?.titleSet == 1)
        #expect(DVDDisc.titleSetPart(of: "VTS_01_1.VOB")?.part == 1)
        #expect(DVDDisc.titleSetPart(of: "vts_12_3.vob")?.titleSet == 12)
        #expect(DVDDisc.titleSetPart(of: "VTS_01_0.VOB") == nil)
        #expect(DVDDisc.titleSetPart(of: "VIDEO_TS.VOB") == nil)
        #expect(DVDDisc.titleSetPart(of: "VTS_01_0.IFO") == nil)
    }

    @Test func aStreamMapTranslatesEveryOffsetOntoTheImage() throws {
        let map = try DiscStreamMap(extents: [
            DiscExtent(offset: 1_000, length: 100),
            DiscExtent(offset: 50_000, length: 50),
        ])
        #expect(map.length == 150)
        // The start of each extent, a byte inside one, and the last byte.
        #expect(map.locate(0)?.imageOffset == 1_000)
        #expect(map.locate(99)?.imageOffset == 1_099)
        #expect(map.locate(100)?.imageOffset == 50_000)
        #expect(map.locate(149)?.imageOffset == 50_049)
        // A read never runs past its extent: the next bytes live elsewhere in
        // the image.
        #expect(map.locate(90)?.available == 10)
        #expect(map.locate(0)?.available == 100)
        // Past the end, and before it.
        #expect(map.locate(150) == nil)
        #expect(map.locate(-1) == nil)
    }

    @Test func theServersRuntimePicksBetweenTitlesOfSimilarLength() {
        // From a real disc: four titles between 98.2 and 98.7 minutes, and only
        // the server's 98.11 picks the right one.
        let candidates = [
            BlurayPlaylist(name: "00004.mpls", items: [.init(clip: "00056", seconds: 5_892)]),
            BlurayPlaylist(name: "00801.mpls", items: [.init(clip: "00056", seconds: 5_922)]),
        ]
        #expect(BlurayTitlePolicy.mainTitle(from: candidates, runtimeSeconds: 5_886)?.name == "00004.mpls")
        #expect(BlurayTitlePolicy.mainTitle(from: candidates, runtimeSeconds: 5_930)?.name == "00801.mpls")
    }

    @Test func aMenuLoopNeverWinsTheTitle() {
        // A real menu loop: two clips played 303 times report 323 minutes, more
        // than the disc holds. Counting each clip once gives two minutes.
        let loop = BlurayPlaylist(
            name: "00020.mpls",
            items: Array(repeating: .init(clip: "00041", seconds: 64), count: 303)
        )
        let film = BlurayPlaylist(name: "00004.mpls", items: [.init(clip: "00056", seconds: 5_892)])
        #expect(loop.seconds > film.seconds)
        #expect(loop.collapsedSeconds < film.collapsedSeconds)
        #expect(BlurayTitlePolicy.mainTitle(from: [loop, film], runtimeSeconds: nil)?.name == "00004.mpls")
    }

    @Test func identicalTitlesResolveByNameSoTheChoiceIsStable() {
        // 00004 and 00800 are the same film; directory order must not decide.
        let items: [BlurayPlaylist.Item] = [.init(clip: "00056", seconds: 5_892)]
        let forwards = [
            BlurayPlaylist(name: "00800.mpls", items: items),
            BlurayPlaylist(name: "00004.mpls", items: items),
        ]
        #expect(BlurayTitlePolicy.mainTitle(from: forwards, runtimeSeconds: 5_886)?.name == "00004.mpls")
        #expect(BlurayTitlePolicy.mainTitle(from: forwards.reversed(), runtimeSeconds: nil)?.name == "00004.mpls")
    }

    @Test func aTitleStreamNeverReadsPastTheExtentItStartedIn() throws {
        // AVIO asks for whole buffers. Serving one across an extent boundary
        // would silently splice in bytes from elsewhere, so a short read is the
        // only right answer.
        let underlying = RecordingByteSource()
        let stream = DiscImageStream(
            source: underlying,
            map: try DiscStreamMap(extents: [
                DiscExtent(offset: 1_000, length: 100),
                DiscExtent(offset: 50_000, length: 50),
            ])
        )

        #expect(stream.contentLength == 150)
        #expect(stream.requestSize == underlying.requestSize)

        let first = try stream.read(offset: 0, length: 4_096, priority: 1)
        #expect(first.count == 100)
        #expect(underlying.reads.last?.offset == 1_000)
        #expect(underlying.reads.last?.length == 100)

        let second = try stream.read(offset: 100, length: 4_096, priority: 1)
        #expect(second.count == 50)
        #expect(underlying.reads.last?.offset == 50_000)

        // Past the end reads nothing rather than reading somewhere wrong.
        #expect(try stream.read(offset: 150, length: 16, priority: 1).isEmpty)

        // The cache reads ahead in image bytes, so the anchor is mapped too.
        stream.setTimelineAnchor(byteOffset: 120, timeFraction: 0.8)
        #expect(underlying.anchors.last?.byteOffset == 50_020)
        #expect(underlying.anchors.last?.timeFraction == 0.8)
    }

    @Test func aPlaylistIsParsedBigEndianOnALittleEndianFilesystem() throws {
        let parsed = try BlurayPlaylistParser.parse(
            Data(makePlaylist(items: [("00056", 120), ("00061", 90)])),
            name: "00004.mpls"
        )
        #expect(parsed.items.map(\.clip) == ["00056", "00061"])
        #expect(parsed.seconds == 210)
        #expect(!parsed.items.isEmpty)
    }
}

/// Stands in for the playback cache under the disc layers.
private final class RecordingByteSource: FFmpegByteSource {
    let requestSize: Int64 = 64 * 1_024
    var contentLength: Int64? = 1_000_000
    private(set) var reads: [(offset: Int64, length: Int)] = []
    private(set) var anchors: [(byteOffset: Int64, timeFraction: Double)] = []

    func read(offset: Int64, length: Int, priority: Float) throws -> Data {
        reads.append((offset, length))
        return Data(repeating: UInt8(truncatingIfNeeded: offset), count: length)
    }

    func setTimelineAnchor(byteOffset: Int64, timeFraction: Double) {
        anchors.append((byteOffset, timeFraction))
    }
}
