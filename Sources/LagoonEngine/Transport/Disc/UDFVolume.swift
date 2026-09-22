import Foundation

/// Enough read-only UDF to find a file and say where its bytes are.
///
/// Not a general filesystem: it resolves names to extents and reads small
/// files whole, which is all a disc image needs before the demuxer takes
/// over. Written rather than linked because libavformat has no UDF at all,
/// and libbluray/libudfread would be a new dependency that still could not
/// reach a disc over HTTP without the same callbacks.
///
/// UDF 2.50, which is what BD-ROM uses, keeps every file entry inside a
/// *metadata partition* — a file in the physical partition that the volume
/// then addresses as if it were a partition of its own. That indirection is
/// the part worth knowing about: file entries live there, while the file data
/// they describe lives in the physical partition, and a reader that misses
/// the distinction reads empty directories.
nonisolated final class UDFVolume {
    /// Where a file entry lives. `partition` is a reference into the volume's
    /// partition map, not a partition number.
    struct ICB: Equatable {
        let block: UInt32
        let partition: UInt16
        let length: UInt32
    }

    struct Entry: Equatable {
        let name: String
        let isDirectory: Bool
        let icb: ICB
    }

    /// A file's bytes: where they are, or — for a file small enough that UDF
    /// stored it inside its own entry — what they are.
    enum Contents: Equatable {
        case extents([DiscExtent])
        case embedded(Data)
    }

    private enum Tag {
        static let anchor: UInt16 = 2
        static let partition: UInt16 = 5
        static let logicalVolume: UInt16 = 6
        static let terminating: UInt16 = 8
        static let fileSet: UInt16 = 256
        static let fileIdentifier: UInt16 = 257
        static let allocationExtent: UInt16 = 258
        static let fileEntry: UInt16 = 261
        static let extendedFileEntry: UInt16 = 266
    }

    /// The anchor is at a fixed logical sector, which is what makes "is this
    /// a UDF image at all" a cheap question to answer.
    private static let anchorSector: Int64 = 256
    private static let sectorSize: Int64 = 2_048
    /// Bounds on a structure a server handed us: a malformed image should
    /// fail the open, never spin.
    private static let maxVolumeDescriptors = 64
    private static let maxExtents = 8_192
    private static let maxAllocationContinuations = 64
    private static let maxDirectoryBytes = 4 * 1_024 * 1_024
    private static let maxDirectoryEntries = 16_384

    private let source: DiscImageSource
    let budget: DiscReadBudget
    private var blockSize: Int64 = UDFVolume.sectorSize
    private var partitionStart: Int64 = 0
    private var partitionBlocks: Int64 = 0
    private var partitionNumber: UInt16 = 0
    private var physicalReferences: Set<UInt16> = []
    private var metadataPartition: UInt16?
    private var metadataExtents: [DiscExtent] = []
    private(set) var root = ICB(block: 0, partition: 0, length: 0)

    init(source: DiscImageSource, budget: DiscReadBudget = DiscReadBudget()) throws {
        self.source = source
        self.budget = budget
        try mount()
    }

    func checkBudget() throws { try budget.check() }

    // MARK: - Mounting

    private func mount() throws {
        let anchor = try sector(at: Self.anchorSector)
        guard try anchor.u16(0) == Tag.anchor else { throw DiscImageError.notUDF }
        let sequenceLength = Int64(try anchor.u32(16))
        let sequenceStart = Int64(try anchor.u32(20))

        var partitionDescriptor: DiscBytes?
        var logicalVolume: DiscBytes?
        guard sequenceLength >= Self.sectorSize,
              sequenceLength <= Int64(Self.maxVolumeDescriptors) * Self.sectorSize else {
            throw DiscImageError.resourceLimit
        }
        try validateImageRange(offset: sequenceStart * Self.sectorSize, length: sequenceLength)
        let sectors = sequenceLength / Self.sectorSize
        for index in 0..<sectors {
            let descriptor = try sector(at: sequenceStart + index)
            switch try descriptor.u16(0) {
            case Tag.partition: partitionDescriptor = descriptor
            case Tag.logicalVolume: logicalVolume = descriptor
            case Tag.terminating: break
            default: continue
            }
            if try descriptor.u16(0) == Tag.terminating { break }
        }
        guard let partitionDescriptor, let logicalVolume else {
            throw DiscImageError.malformed("no partition or logical volume descriptor")
        }

        partitionStart = Int64(try partitionDescriptor.u32(188))
        partitionBlocks = Int64(try partitionDescriptor.u32(192))
        partitionNumber = try partitionDescriptor.u16(22)
        let declaredBlockSize = Int64(try logicalVolume.u32(212))
        guard declaredBlockSize >= 512, declaredBlockSize <= 65_536,
              declaredBlockSize & (declaredBlockSize - 1) == 0, partitionBlocks > 0 else {
            throw DiscImageError.malformed("logical block size \(declaredBlockSize)")
        }
        blockSize = declaredBlockSize
        try validateImageRange(offset: partitionStart * blockSize, length: partitionBlocks * blockSize)

        try mountMetadataPartition(in: logicalVolume)

        let fileSetLocation = try longAD(logicalVolume, at: 248)
        let fileSet = try read(
            block: fileSetLocation.block,
            partition: fileSetLocation.partition,
            count: Int(Self.sectorSize)
        )
        guard try fileSet.u16(0) == Tag.fileSet else {
            throw DiscImageError.malformed("no file set descriptor")
        }
        root = try longAD(fileSet, at: 400)
    }

    /// UDF 2.50's metadata partition, which every BD-ROM image uses. Its file
    /// is described in the physical partition; once its extents are known,
    /// logical blocks addressed to that partition are offsets into it.
    private func mountMetadataPartition(in logicalVolume: DiscBytes) throws {
        let count = Int(try logicalVolume.u32(268))
        let tableLength = Int(try logicalVolume.u32(264))
        guard count > 0, count <= Self.maxVolumeDescriptors else { throw DiscImageError.resourceLimit }
        try logicalVolume.require(440, tableLength)
        let end = 440 + tableLength
        var offset = 440
        var metadataFile: (reference: UInt16, block: UInt32)?
        for reference in 0..<count {
            try checkBudget()
            guard offset <= end - 2 else { throw DiscImageError.malformed("truncated partition map") }
            let kind = try logicalVolume.u8(offset)
            let length = Int(try logicalVolume.u8(offset + 1))
            guard length >= 2, length <= end - offset else {
                throw DiscImageError.malformed("invalid partition map length")
            }
            if kind == 1, length == 6, try logicalVolume.u16(offset + 4) == partitionNumber {
                physicalReferences.insert(UInt16(reference))
            } else if kind == 2, length == 64,
                      try logicalVolume.identifier(offset + 4) == "*UDF Metadata Partition",
                      try logicalVolume.u16(offset + 38) == partitionNumber, metadataFile == nil {
                metadataFile = (UInt16(reference), try logicalVolume.u32(offset + 40))
            } else {
                throw DiscImageError.unsupported("partition map")
            }
            offset += length
        }
        guard offset == end else { throw DiscImageError.malformed("partition map count/length mismatch") }
        if let metadataFile {
            let entry = try physical(block: metadataFile.block, count: Int(blockSize))
            // Read with no metadata mapping in place yet: the metadata
            // file itself is always described in the physical partition.
            guard case .extents(let extents) = try contents(ofEntry: entry, partition: nil) else {
                throw DiscImageError.malformed("metadata file stored inside its own entry")
            }
            metadataExtents = extents
            guard !extents.isEmpty else { throw DiscImageError.malformed("empty metadata partition") }
            metadataPartition = metadataFile.reference
        }
    }

    // MARK: - Addressing

    private func sector(at index: Int64) throws -> DiscBytes {
        DiscBytes(try readImage(at: index * Self.sectorSize, count: Int(Self.sectorSize)))
    }

    private func physical(block: UInt32, count: Int) throws -> DiscBytes {
        try validatePhysical(block: block, length: Int64(count))
        return DiscBytes(try readImage(at: (partitionStart + Int64(block)) * blockSize, count: count))
    }

    private func validateImageRange(offset: Int64, length: Int64) throws {
        guard offset >= 0, length >= 0, length <= Int64.max - offset else {
            throw DiscImageError.malformed("image extent overflow")
        }
        if let imageLength = source.imageLength {
            guard imageLength >= 0, offset <= imageLength, length <= imageLength - offset else {
                throw DiscImageError.malformed("extent outside the image")
            }
        }
    }

    private func validatePhysical(block: UInt32, length: Int64) throws {
        let offset = Int64(block) * blockSize
        let size = partitionBlocks * blockSize
        guard length >= 0, offset <= size, length <= size - offset else {
            throw DiscImageError.malformed("extent outside the partition")
        }
        try validateImageRange(offset: partitionStart * blockSize + offset, length: length)
    }

    private func readImage(at offset: Int64, count: Int) throws -> Data {
        try validateImageRange(offset: offset, length: Int64(count))
        try budget.read(count)
        let data = try source.read(at: offset, count: count)
        try checkBudget()
        guard data.count == count else { throw DiscImageError.malformed("truncated image read") }
        return data
    }

    /// Image extents for a run of logical blocks, resolved through the
    /// metadata partition when the descriptor names it. A metadata run can
    /// cross the metadata file's own extents, so this may return several.
    private func imageExtents(block: UInt32, length: Int64, partition: UInt16?) throws -> [DiscExtent] {
        try checkBudget()
        guard length >= 0 else { throw DiscImageError.malformed("negative extent length") }
        if let partition, partition != metadataPartition, !physicalReferences.contains(partition) {
            throw DiscImageError.malformed("unknown partition reference")
        }
        guard let partition, partition == metadataPartition, !metadataExtents.isEmpty else {
            try validatePhysical(block: block, length: length)
            return [DiscExtent(offset: (partitionStart + Int64(block)) * blockSize, length: length)]
        }
        var offset = Int64(block) * blockSize
        var remaining = length
        var mapped: [DiscExtent] = []
        for extent in metadataExtents {
            try checkBudget()
            guard remaining > 0 else { break }
            if offset >= extent.length {
                offset -= extent.length
                continue
            }
            let take = min(remaining, extent.length - offset)
            mapped.append(DiscExtent(offset: extent.offset + offset, length: take))
            remaining -= take
            offset = 0
        }
        guard remaining == 0 else { throw DiscImageError.malformed("extent outside the metadata partition") }
        return mapped
    }

    private func read(block: UInt32, partition: UInt16?, count: Int) throws -> DiscBytes {
        guard count >= 0, count <= DiscReadBudget.maxReadBytes else { throw DiscImageError.resourceLimit }
        var data = Data()
        for extent in try imageExtents(block: block, length: Int64(count), partition: partition) {
            data += try readImage(at: extent.offset, count: Int(extent.length))
        }
        return DiscBytes(data)
    }

    private func longAD(_ bytes: DiscBytes, at offset: Int) throws -> ICB {
        ICB(
            block: try bytes.u32(offset + 4),
            partition: try bytes.u16(offset + 8),
            length: try bytes.u32(offset) & 0x3FFF_FFFF
        )
    }

    // MARK: - File entries

    func entry(_ icb: ICB) throws -> DiscBytes {
        guard icb.length <= DiscReadBudget.maxReadBytes else { throw DiscImageError.resourceLimit }
        return try read(
            block: icb.block,
            partition: icb.partition,
            count: max(Int(blockSize), Int(icb.length))
        )
    }

    /// The extents of a file, in image bytes, or its contents when UDF stored
    /// them inside the entry.
    func contents(of icb: ICB) throws -> Contents {
        try contents(ofEntry: try entry(icb), partition: icb.partition)
    }

    private func contents(ofEntry entry: DiscBytes, partition: UInt16?) throws -> Contents {
        let tag = try entry.u16(0)
        let descriptorType = try entry.u16(34) & 0x07
        let extendedAttributes: Int
        let descriptors: Int
        let base: Int
        switch tag {
        case Tag.extendedFileEntry:
            extendedAttributes = Int(try entry.u32(208))
            descriptors = Int(try entry.u32(212))
            base = 216
        case Tag.fileEntry:
            extendedAttributes = Int(try entry.u32(168))
            descriptors = Int(try entry.u32(172))
            base = 176
        default:
            throw DiscImageError.malformed("expected a file entry, found tag \(tag)")
        }

        var bytes = entry
        var offset = base + extendedAttributes
        var end = offset + descriptors
        try bytes.require(offset, descriptors)
        if descriptorType == 3 {
            return .embedded(try bytes.bytes(offset, descriptors))
        }
        guard descriptorType == 0 || descriptorType == 1 else {
            throw DiscImageError.unsupported("allocation descriptor type \(descriptorType)")
        }

        var extents: [DiscExtent] = []
        var continuations = 0
        var visited: Set<String> = []
        while offset < end {
            try checkBudget()
            let descriptorSize = descriptorType == 0 ? 8 : 16
            guard descriptorSize <= end - offset else {
                throw DiscImageError.malformed("truncated allocation descriptor")
            }
            let rawLength: UInt32
            let block: UInt32
            let extentPartition: UInt16?
            if descriptorType == 0 {
                rawLength = try bytes.u32(offset)
                block = try bytes.u32(offset + 4)
                extentPartition = partition
                offset += 8
            } else {
                rawLength = try bytes.u32(offset)
                block = try bytes.u32(offset + 4)
                extentPartition = try bytes.u16(offset + 8)
                offset += 16
            }
            let length = Int64(rawLength & 0x3FFF_FFFF)
            switch rawLength >> 30 {
            case 3:
                // The descriptors continue in a block of their own.
                continuations += 1
                guard continuations <= Self.maxAllocationContinuations else {
                    throw DiscImageError.malformed("allocation descriptors never end")
                }
                guard length > 0, length <= DiscReadBudget.maxReadBytes,
                      visited.insert("\(extentPartition.map(String.init) ?? "physical"):\(block)").inserted else {
                    throw DiscImageError.malformed("invalid allocation continuation")
                }
                let continuation = try read(
                    block: block,
                    partition: extentPartition,
                    count: max(Int(blockSize), Int(length))
                )
                guard try continuation.u16(0) == Tag.allocationExtent else {
                    throw DiscImageError.malformed("expected an allocation extent descriptor")
                }
                bytes = continuation
                offset = 24
                end = 24 + Int(try continuation.u32(20))
                try continuation.require(24, end - 24)
            case 0 where length > 0:
                let mapped = try imageExtents(
                    block: block,
                    length: length,
                    partition: extentPartition
                )
                guard mapped.count <= Self.maxExtents - extents.count else { throw DiscImageError.resourceLimit }
                extents.append(contentsOf: mapped)
            default:
                // Allocated but not recorded, or a terminator. Neither has
                // bytes to read.
                if length == 0 { offset = end }
                else { throw DiscImageError.unsupported("unrecorded file extents") }
            }
        }
        return .extents(extents)
    }

    /// A whole file, for the small ones this reader is allowed to open: a
    /// directory, a playlist. Never a stream.
    func data(of icb: ICB, limit: Int = UDFVolume.maxDirectoryBytes) throws -> Data {
        guard limit >= 0, limit <= Self.maxDirectoryBytes else { throw DiscImageError.resourceLimit }
        switch try contents(of: icb) {
        case .embedded(let data):
            guard data.count <= limit else { throw DiscImageError.resourceLimit }
            return data
        case .extents(let extents):
            var total: Int64 = 0
            for extent in extents {
                guard extent.length <= Int64(limit) - total else { throw DiscImageError.resourceLimit }
                total += extent.length
            }
            var data = Data()
            for extent in extents {
                var consumed: Int64 = 0
                while consumed < extent.length {
                    let take = Int(min(extent.length - consumed, Int64(DiscReadBudget.maxReadBytes)))
                    data += try readImage(at: extent.offset + consumed, count: take)
                    consumed += Int64(take)
                }
            }
            return data
        }
    }

    // MARK: - Directories

    func list(_ icb: ICB) throws -> [Entry] {
        let data = DiscBytes(try data(of: icb))
        var entries: [Entry] = []
        var offset = 0
        while offset + 38 <= data.count {
            try checkBudget()
            let tag = try data.u16(offset)
            if tag == 0, try data.bytes(offset, data.count - offset).allSatisfy({ $0 == 0 }) { break }
            guard tag == Tag.fileIdentifier else { throw DiscImageError.malformed("invalid directory entry") }
            let characteristics = try data.u8(offset + 18)
            let nameLength = Int(try data.u8(offset + 19))
            let child = try longAD(data, at: offset + 20)
            let implementationUse = Int(try data.u16(offset + 36))
            let nameOffset = offset + 38 + implementationUse
            try data.require(nameOffset, nameLength)
            // Bit 3 marks the entry pointing back at the parent directory,
            // which has no name and is not a child.
            if characteristics & 0x08 == 0, nameLength > 0 {
                guard entries.count < Self.maxDirectoryEntries else { throw DiscImageError.resourceLimit }
                let raw = try data.bytes(nameOffset, nameLength)
                entries.append(Entry(
                    name: DiscBytes.characters(raw),
                    isDirectory: characteristics & 0x02 != 0,
                    icb: child
                ))
            }
            var length = 38 + implementationUse + nameLength
            length += (4 - (length % 4)) % 4
            try data.require(offset, length)
            guard length > 0 else { break }
            offset += length
        }
        if offset < data.count, data.count - offset < 38,
           try !data.bytes(offset, data.count - offset).allSatisfy({ $0 == 0 }) {
            throw DiscImageError.malformed("truncated directory entry")
        }
        return entries
    }

    /// Resolve a slash-separated path from the root. Case-insensitive: the
    /// specification uppercases BDMV's names, and images in the wild are not
    /// uniformly obedient about it.
    func entry(at path: String) throws -> Entry? {
        var current = Entry(name: "", isDirectory: true, icb: root)
        for component in path.split(separator: "/") {
            try checkBudget()
            guard current.isDirectory else { return nil }
            let name = component.uppercased()
            guard let next = try list(current.icb).first(where: { $0.name.uppercased() == name }) else {
                return nil
            }
            current = next
        }
        return current
    }
}
