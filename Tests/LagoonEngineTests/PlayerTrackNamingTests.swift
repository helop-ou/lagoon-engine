import Testing
@testable import LagoonEngine

@Suite("Player track naming")
struct PlayerTrackNamingTests {
    /// Identical track names give the viewer nothing to pick by.
    @Test func collidingTrackNamesGainTheirPositionAndUniqueOnesDoNot() {
        let tracks = [
            PlayerTrack(engineID: 1, kind: .audio, displayName: "DTS 5.1", isSelected: false),
            PlayerTrack(engineID: 2, kind: .audio, displayName: "DTS 5.1", isSelected: true),
            PlayerTrack(engineID: 3, kind: .audio, displayName: "DTS 5.1", isSelected: false),
            PlayerTrack(
                engineID: 4,
                kind: .audio,
                displayName: "Dolby Digital Stereo",
                isSelected: false
            ),
        ]

        let named = SampleBufferPlayerEngine.disambiguated(tracks)

        #expect(named.map(\.displayName) == [
            "DTS 5.1 · Track 1",
            "DTS 5.1 · Track 2",
            "DTS 5.1 · Track 3",
            "Dolby Digital Stereo",
        ])
        // Renaming leaves ordinals and selection alone.
        #expect(named.map(\.engineID) == [1, 2, 3, 4])
        #expect(named.filter(\.isSelected).map(\.engineID) == [2])
    }

    @Test func namesThatAreAlreadyDistinctAreLeftAlone() {
        let tracks = [
            PlayerTrack(engineID: 1, kind: .audio, displayName: "English", isSelected: true),
            PlayerTrack(engineID: 2, kind: .audio, displayName: "Russian", isSelected: false),
        ]

        #expect(SampleBufferPlayerEngine.disambiguated(tracks) == tracks)
    }
}
