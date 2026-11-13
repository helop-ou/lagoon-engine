import Foundation
import Testing
@testable import LagoonEngine

@Suite("Playback failure detail")
struct PlaybackFailureDetailTests {
    @Test func onlyDomainAndCodeSurviveAnError() {
        let error = NSError(domain: "NSURLErrorDomain", code: -1200, userInfo: [
            NSLocalizedDescriptionKey: "An SSL error has occurred and a secure connection to https://lagoonfix.example.eu cannot be made.",
            NSURLErrorFailingURLErrorKey: URL(string: "https://lagoonfix.example.eu/Videos/1/stream?api_key=secret") as Any,
        ])
        let detail = PlaybackFailureDetail(stage: .open, error: error)
        #expect(detail.fields == ["stage": .string("open"), "errorDomain": .string("NSURLErrorDomain"), "errorCode": .int(-1200)])
        #expect(detail.fingerprint == ["open", "NSURLErrorDomain", "-1200"])
    }

    /// Reports are grouped by these names, so a stage keeps the one it had
    /// as an enum case.
    @Test func theEnginesStagesKeepTheNamesReportsAreGroupedBy() {
        let stages: [PlaybackFailureDetail.Stage] = [
            .open, .seek, .read, .decode, .videoRenderer, .audioRenderer, .subtitle,
        ]

        #expect(stages.map(\.rawValue) == [
            "open", "seek", "read", "decode", "videoRenderer", "audioRenderer", "subtitle",
        ])
    }

    @Test func aHostsOwnStageIsReportedUnderItsName() {
        let detail = PlaybackFailureDetail(stage: .init(rawValue: "negotiate"), domain: "HostError.server", code: 503)

        #expect(detail.fields == ["stage": .string("negotiate"), "errorDomain": .string("HostError.server"), "errorCode": .int(503)])
        #expect(detail.fingerprint == ["negotiate", "HostError.server", "503"])
    }

    /// A stage is whatever string a host gives it, so it passes the same
    /// rule as a domain before it reaches a report.
    @Test func aStageThatCouldBeAnAddressIsLeftOut() {
        let stage = PlaybackFailureDetail.Stage(rawValue: "https://media.test/Videos/1/stream")
        let detail = PlaybackFailureDetail(stage: stage, domain: "ffmpeg", code: -5)

        #expect(detail.fields == ["errorDomain": .string("ffmpeg"), "errorCode": .int(-5)])
        #expect(detail.fingerprint == ["ffmpeg", "-5"])
    }
}
