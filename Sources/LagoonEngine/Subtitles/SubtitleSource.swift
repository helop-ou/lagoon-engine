import Foundation

/// One remote subtitle result as Jellyfin reports it. The player UI binds to
/// this rather than to the wire DTO so the panel does not follow the server's
/// shape. Jellyfin is the only source: its routes need
/// the account's subtitle-management permission and persist the file for
/// every client, and the server does the provider work with its own accounts.
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
    /// The identifier Jellyfin needs to fetch this result.
    let jellyfinID: String

    init(_ info: RemoteSubtitleInfo) {
        id = "jellyfin:" + info.id
        name = info.name
        language = info.threeLetterISOLanguageName
        providerName = info.providerName
        format = info.format
        downloadCount = info.downloadCount
        isHashMatch = info.isHashMatch == true
        isHearingImpaired = info.hearingImpaired == true
        isForced = info.isForced == true
        isMachineTranslated = info.machineTranslated == true
        isAITranslated = info.aiTranslated == true
        jellyfinID = info.id
    }

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
        jellyfinID = id
    }
    #endif
}
