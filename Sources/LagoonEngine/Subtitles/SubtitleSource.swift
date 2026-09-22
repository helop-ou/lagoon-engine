import Foundation

/// One subtitle a host has found and could fetch, in the engine's own terms.
///
/// A host maps whatever its server reports onto this, so neither the engine
/// nor a player panel bound to it follows any one server's wire shape.
public nonisolated struct SubtitleCandidate: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String?
    public let language: String?
    public let providerName: String?
    public let format: String?
    public let downloadCount: Int?
    public let isHashMatch: Bool
    public let isHearingImpaired: Bool
    public let isForced: Bool
    public let isMachineTranslated: Bool
    public let isAITranslated: Bool
    /// The host's own identifier for fetching this result. Opaque here: the
    /// engine never parses it, it only hands it back.
    public let providerID: String

    public init(
        id: String,
        providerID: String,
        name: String? = nil,
        language: String? = nil,
        providerName: String? = nil,
        format: String? = nil,
        downloadCount: Int? = nil,
        isHashMatch: Bool = false,
        isHearingImpaired: Bool = false,
        isForced: Bool = false,
        isMachineTranslated: Bool = false,
        isAITranslated: Bool = false
    ) {
        self.id = id
        self.providerID = providerID
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

    #if DEBUG
    /// Fixture for the Debug component gallery, which has no server to ask.
    public init(
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
        providerID = id
    }
    #endif
}
