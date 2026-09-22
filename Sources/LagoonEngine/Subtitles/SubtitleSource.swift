import Foundation

/// One subtitle a host has found and could fetch, in the engine's own terms.
///
/// A host maps whatever its server reports onto this, so neither the engine
/// nor a player panel bound to it follows any one server's wire shape.
nonisolated struct SubtitleCandidate: Identifiable, Equatable, Sendable {
    let id: String
    let name: String?
    let language: String?
    let providerName: String?
    let format: String?
    let downloadCount: Int?
    let isHashMatch: Bool
    let isHearingImpaired: Bool
    let isForced: Bool
    let isMachineTranslated: Bool
    let isAITranslated: Bool

    #if DEBUG
    /// Fixture for the Debug component gallery, which has no server to ask.
    init(
        id: String,
        name: String?,
        language: String?,
        providerName: String?,
        format: String?,
        downloadCount: Int? = nil,
        isHashMatch: Bool = false,
        isHearingImpaired: Bool = false,
        isForced: Bool = false,
        isMachineTranslated: Bool = false,
        isAITranslated: Bool = false
    ) {
        self.id = id
        self.name = name
        self.language = language
        self.providerName = providerName
        self.format = format
        self.downloadCount = downloadCount
        self.isHashMatch = isHashMatch
        self.isHearingImpaired = isHearingImpaired
        self.isForced = isForced
        self.isMachineTranslated = isMachineTranslated
        self.isAITranslated = isAITranslated
    }
    #endif
}
