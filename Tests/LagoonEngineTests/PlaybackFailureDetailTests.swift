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
}
