import Foundation
import Testing
@testable import LagoonEngine

/// A transient network fault is ridden out on a time budget; a request that
/// will fail the same way again is not retried.
@Suite("Network retry policy")
struct NetworkRetryPolicyTests {
    @Test func pausesGrowThenHoldAtTheLastStep() {
        let policy = NetworkRetryPolicy.playback
        let pauses = (0..<6).compactMap { policy.delay(beforeAttempt: $0, elapsedSinceFirstFailure: 0) }
        #expect(pauses == [0.25, 0.5, 1, 2, 2, 2])
    }

    @Test func theBudgetEndsTheRetries() {
        let policy = NetworkRetryPolicy.playback
        #expect(policy.delay(beforeAttempt: 20, elapsedSinceFirstFailure: 27.9) == 2)
        #expect(policy.delay(beforeAttempt: 20, elapsedSinceFirstFailure: 28.1) == nil)
        #expect(NetworkRetryPolicy(budget: 5, delays: []).delay(beforeAttempt: 0, elapsedSinceFirstFailure: 0) == nil)
    }

    @Test func aDeadNetworkOrABusyServerIsTransient() {
        for code in [URLError.Code.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost, .dnsLookupFailed] {
            #expect(NetworkRetryPolicy.isTransient(URLError(code)))
        }
        for status in [500, 502, 503, 504, 408, 429] {
            #expect(NetworkRetryPolicy.isTransient(FFmpegTransportError.httpStatus(status)))
            #expect(NetworkRetryPolicy.isTransient(PlaybackCacheError.serverStatus(status)))
        }
        #expect(NetworkRetryPolicy.isTransient(FFmpegTransportError.timeout))
    }

    @Test func aRequestThatWillFailAgainIsNot() {
        for code in [URLError.Code.cancelled, .badURL, .serverCertificateUntrusted, .userAuthenticationRequired] {
            #expect(!NetworkRetryPolicy.isTransient(URLError(code)))
        }
        for status in [400, 401, 403, 404, 416] {
            #expect(!NetworkRetryPolicy.isTransient(FFmpegTransportError.httpStatus(status)))
        }
        #expect(!NetworkRetryPolicy.isTransient(FFmpegTransportError.invalidResponse))
        #expect(!NetworkRetryPolicy.isTransient(PlaybackCacheError.rangeUnsupported))
    }

    @Test func aPauseEndsEarlyWhenTheReadIsNoLongerWanted() {
        let start = Date()
        #expect(!NetworkRetryPolicy.pause(5, unless: { Date().timeIntervalSince(start) > 0.15 }))
        #expect(Date().timeIntervalSince(start) < 1)
        #expect(NetworkRetryPolicy.pause(0.05, unless: { false }))
    }
}
