import Foundation

/// The DVD-Video half of disc reading.
///
/// Far less work than Blu-ray turned out to need, for two reasons. The
/// filesystem is the same one already written: a DVD image is UDF 1.02, which
/// is the 2.50 reader minus the metadata partition, and it mounts unchanged.
/// And a title is not assembled from a playlist but simply *is* a title set's
/// VOB files in numeric order, split at 1 GB because that is as much as the
/// filesystem was ever asked to address in one file.
nonisolated enum DVDDisc {
    static let directory = "VIDEO_TS"

    /// `VTS_01_2.VOB` -> title set 1, part 2.
    ///
    /// Part 0 is deliberately excluded: `VTS_nn_0.VOB` is that title set's
    /// menu, not its film, and `VIDEO_TS.VOB` is the disc's own menu.
    static func titleSetPart(of name: String) -> (titleSet: Int, part: Int)? {
        let upper = name.uppercased()
        guard upper.utf8.count == 12, upper.hasPrefix("VTS_"), upper.hasSuffix(".VOB") else { return nil }
        let stem = upper.dropFirst(4).dropLast(4)     // "01_2"
        let pieces = stem.split(separator: "_")
        guard pieces.count == 2,
              let titleSet = Int(pieces[0]),
              let part = Int(pieces[1]),
              pieces[0].count == 2, pieces[1].count == 1,
              pieces[0].utf8.allSatisfy({ (48...57).contains($0) }),
              pieces[1].utf8.allSatisfy({ (48...57).contains($0) }),
              (1...99).contains(titleSet), (1...9).contains(part) else { return nil }
        return (titleSet, part)
    }

    static func isDVD(_ volume: UDFVolume) throws -> Bool {
        try volume.entry(at: directory) != nil
    }

    /// The largest title set, its parts laid end to end.
    ///
    /// Size rather than a program chain read out of the IFO files. On a disc
    /// holding one film this is the film, which is the case worth getting
    /// right first; a disc of episodes keeps them in one title set and will
    /// play them in sequence, which is the honest limitation of choosing this
    /// way and is recorded on the ticket rather than hidden here.
    static func mainTitle(in volume: UDFVolume) throws -> DiscStreamMap {
        guard let videoTS = try volume.entry(at: directory) else {
            throw DiscImageError.noTitle
        }
        var parts: [Int: [(part: Int, extents: [DiscExtent])]] = [:]
        var totalExtents = 0
        var sizes: [Int: Int64] = [:]
        for entry in try volume.list(videoTS.icb) where !entry.isDirectory {
            try volume.checkBudget()
            guard let position = titleSetPart(of: entry.name) else { continue }
            guard case .extents(let extents) = try volume.contents(of: entry.icb) else { continue }
            guard extents.count <= DiscStreamMap.maxExtents - totalExtents else { throw DiscImageError.resourceLimit }
            totalExtents += extents.count
            guard parts[position.titleSet]?.contains(where: { $0.part == position.part }) != true else {
                throw DiscImageError.malformed("duplicate DVD title part")
            }
            let size = try DiscStreamMap(extents: extents).length
            let previous = sizes[position.titleSet, default: 0]
            guard size <= Int64.max - previous else { throw DiscImageError.malformed("DVD title size overflow") }
            sizes[position.titleSet] = previous + size
            parts[position.titleSet, default: []].append((position.part, extents))
        }
        guard let chosen = parts.max(by: { left, right in
            let leftBytes = sizes[left.key, default: 0]
            let rightBytes = sizes[right.key, default: 0]
            // Ties by title set number, so the choice cannot depend on
            // dictionary order.
            return leftBytes == rightBytes ? left.key > right.key : leftBytes < rightBytes
        }) else {
            throw DiscImageError.noTitle
        }
        let ordered = chosen.value.sorted { $0.part < $1.part }
        guard ordered.enumerated().allSatisfy({ $0.element.part == $0.offset + 1 }) else {
            throw DiscImageError.malformed("missing DVD title part")
        }
        let extents = ordered.flatMap(\.extents)
        guard !extents.isEmpty else { throw DiscImageError.noTitle }
        return try DiscStreamMap(extents: extents)
    }
}

/// Which kind of disc this is, and what to play off it.
///
/// The image says so itself, so nothing upstream has to guess from the
/// server's `IsoType` and be wrong about a mislabelled disc.
nonisolated enum DiscTitle {
    struct Selection {
        /// The playlist a Blu-ray title came from, for diagnostics. nil for a
        /// DVD, which has no such thing.
        let playlist: BlurayPlaylist?
        let stream: DiscStreamMap
    }

    static func mainTitle(in volume: UDFVolume, runtimeSeconds: Double?) throws -> Selection {
        if try BlurayDisc.isBluray(volume) {
            let title = try BlurayDisc.mainTitle(in: volume, runtimeSeconds: runtimeSeconds)
            return Selection(playlist: title.playlist, stream: title.stream)
        }
        if try DVDDisc.isDVD(volume) {
            return Selection(playlist: nil, stream: try DVDDisc.mainTitle(in: volume))
        }
        throw DiscImageError.noTitle
    }
}
