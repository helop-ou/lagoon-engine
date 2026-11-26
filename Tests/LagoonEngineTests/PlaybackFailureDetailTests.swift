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

    /// AVFoundation's `-11800` says nothing: the status underneath does.
    @Test func theErrorUnderneathIsReportedInCodes() {
        let status = NSError(domain: NSOSStatusErrorDomain, code: -12860)
        let error = NSError(domain: "AVFoundationErrorDomain", code: -11800, userInfo: [
            NSLocalizedDescriptionKey: "The operation could not be completed",
            NSUnderlyingErrorKey: status,
        ])
        let detail = PlaybackFailureDetail(stage: .audioRenderer, error: error)

        #expect(detail.fields == [
            "stage": .string("audioRenderer"),
            "errorDomain": .string("AVFoundationErrorDomain"),
            "errorCode": .int(-11800),
            "underlyingDomain": .string("NSOSStatusErrorDomain"),
            "underlyingCode": .int(-12860),
        ])
    }

    @Test func aChainIsFollowedToItsLastError() {
        let posix = NSError(domain: NSPOSIXErrorDomain, code: 54)
        let network = NSError(domain: "kCFErrorDomainCFNetwork", code: -1005, userInfo: [NSUnderlyingErrorKey: posix])
        let error = NSError(domain: NSURLErrorDomain, code: -1005, userInfo: [NSUnderlyingErrorKey: network])
        let detail = PlaybackFailureDetail(stage: .open, error: error)

        #expect(detail.underlyingDomain == NSPOSIXErrorDomain)
        #expect(detail.underlyingCode == 54)
    }

    /// Reports are grouped by the fingerprint, so recording the error
    /// underneath must not move a failure into a new group.
    @Test func theErrorUnderneathStaysOutOfTheFingerprint() {
        let error = NSError(domain: "AVFoundationErrorDomain", code: -11800, userInfo: [
            NSUnderlyingErrorKey: NSError(domain: NSOSStatusErrorDomain, code: -12860),
        ])

        #expect(PlaybackFailureDetail(stage: .audioRenderer, error: error).fingerprint
            == ["audioRenderer", "AVFoundationErrorDomain", "-11800"])
    }

    @Test func nothingElseUnderneathIsRead() {
        let underneath = NSError(domain: "https://lagoonfix.example.eu/Videos/1", code: 7, userInfo: [
            NSLocalizedDescriptionKey: "Could not read /Users/alex/Movies/Sintel.mkv",
            NSURLErrorFailingURLErrorKey: URL(string: "https://lagoonfix.example.eu/Videos/1/stream?api_key=secret") as Any,
        ])
        let error = NSError(domain: NSURLErrorDomain, code: -1200, userInfo: [NSUnderlyingErrorKey: underneath])
        let detail = PlaybackFailureDetail(stage: .open, error: error)

        #expect(detail.fields == [
            "stage": .string("open"),
            "errorDomain": .string("NSURLErrorDomain"),
            "errorCode": .int(-1200),
            "underlyingCode": .int(7),
        ])
    }

    /// `userInfo` is a host's to fill, and nothing stops it from looping.
    @Test func aChainThatNeverEndsStillEnds() {
        final class Loop: NSError {
            override var userInfo: [String: Any] { [NSUnderlyingErrorKey: self] }
        }
        let detail = PlaybackFailureDetail(stage: .read, error: Loop(domain: "Loop", code: 1))

        #expect(detail.underlyingDomain == "Loop")
        #expect(detail.underlyingCode == 1)
    }

    @Test func anErrorWithNothingUnderneathReportsNone() {
        let detail = PlaybackFailureDetail(stage: .seek, error: NSError(domain: "ffmpeg", code: -5))

        #expect(detail.underlyingDomain == nil)
        #expect(detail.underlyingCode == nil)
        #expect(detail.fields == ["stage": .string("seek"), "errorDomain": .string("ffmpeg"), "errorCode": .int(-5)])
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
