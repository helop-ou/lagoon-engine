import AVFoundation
import Foundation
import Libavcodec
import Testing
@testable import LagoonEngine

/// Verdicts the engine reaches alone: whether a decode failure is about the
/// stream or only the restart point, and what a lost VideoToolbox session
/// means. A restart point gets one recovery per playback generation and a
/// session one per fault burst, so a truly undecodable stream still descends
/// the host's ladder, one seek later.
@Suite("Playback engine policies")
struct PlaybackEnginePolicyTests {
    @Test func aDecodeFailureRightAfterAFlushEarnsOneRetryBeforeTheLadder() {
        // Exit 8's shape: the seek's landing picture, then the open GOP's two
        // leading pictures, and the failure names the second. All inside the
        // window.
        for samples in 0...PlaybackRestartPointPolicy.samplesAfterFlush {
            #expect(
                PlaybackRestartPointPolicy.shouldRetryInPlace(
                    videoSamplesSinceFlush: samples,
                    alreadyRetriedThisGeneration: false
                ),
                "\(samples) samples after a flush is a restart-point failure"
            )
        }
    }

    @Test func aFailureInSteadyPlaybackIsAVerdictOnTheStream() {
        // Minutes into a film nothing is known about the restart point; this is
        // the ladder's case.
        #expect(
            !PlaybackRestartPointPolicy.shouldRetryInPlace(
                videoSamplesSinceFlush: PlaybackRestartPointPolicy.samplesAfterFlush + 1,
                alreadyRetriedThisGeneration: false
            )
        )
        #expect(
            !PlaybackRestartPointPolicy.shouldRetryInPlace(
                videoSamplesSinceFlush: 4_000,
                alreadyRetriedThisGeneration: false
            )
        )
    }

    @Test func theRetryCannotLoop() {
        // A second failure at the same position descends, one seek later.
        #expect(
            !PlaybackRestartPointPolicy.shouldRetryInPlace(
                videoSamplesSinceFlush: 0,
                alreadyRetriedThisGeneration: true
            )
        )
    }

    private func session(
        cancelled: Bool = false,
        suspended: Bool = false,
        recovering: Bool = false,
        background: Bool = false,
        generation: Int = 7,
        rebuiltGeneration: Int? = nil,
        framesSinceRebuild: Int = 0
    ) -> PlaybackDecodeSessionPolicy.Resolution {
        PlaybackDecodeSessionPolicy.resolve(
            cancelled: cancelled,
            videoOutputSuspended: suspended,
            recoveryInFlight: recovering,
            hostInBackground: background,
            playbackGeneration: generation,
            rebuiltGeneration: rebuiltGeneration,
            framesSinceRebuild: framesSinceRebuild
        )
    }

    /// A decoder the system took away is rebuilt, not transcoded: `-12903` only
    /// means "make another session".
    @Test func aLostDecodeSessionIsRebuiltRatherThanDescended() {
        #expect(session() == .rebuild)
        // A rebuilt session that fails at once descends, so a session that
        // cannot be made still reaches the ladder.
        #expect(session(rebuiltGeneration: 7) == .descend)
        // A later seek is a new generation with its own rebuild.
        #expect(session(generation: 8, rebuiltGeneration: 7) == .rebuild)
    }

    /// HEL-261: an iPhone in picture in picture lost its session twice, five
    /// minutes apart with no seek between, and the second fault fell back to
    /// a transcode. A rebuild is spent per burst, not per generation.
    @Test func aFaultLongAfterARebuildEarnsAnotherRebuild() {
        let proven = PlaybackDecodeSessionPolicy.provenFrames
        #expect(session(rebuiltGeneration: 7, framesSinceRebuild: proven) == .rebuild)
        #expect(session(rebuiltGeneration: 7, framesSinceRebuild: 7_200) == .rebuild)
        // An immediate repeat is the session that cannot be made.
        #expect(session(rebuiltGeneration: 7, framesSinceRebuild: proven - 1) == .descend)
    }

    /// In the background the system can refuse any new session, so a failed
    /// rebuild waits for the foreground rather than reaching the ladder.
    @Test func aBackgroundFaultThatARebuildCannotFixParksVideo() {
        #expect(session(background: true, rebuiltGeneration: 7) == .park)
        // It still tries a rebuild first: picture in picture can make one.
        #expect(session(background: true) == .rebuild)
        #expect(
            session(
                background: true,
                rebuiltGeneration: 7,
                framesSinceRebuild: PlaybackDecodeSessionPolicy.provenFrames
            ) == .rebuild
        )
        // Once parked, video reads as suspended and the rest are ignored.
        #expect(session(suspended: true, background: true, rebuiltGeneration: 7) == .ignore)
    }

    @Test func everySampleInADeadDecoderIsTheSameOneFault() {
        // Each buffer in the decoder reports the lost session on its way out;
        // without this each would queue a rebuild seek.
        #expect(session(recovering: true) == .alreadyRecovering)
    }

    @Test func suspendedVideoHasNoSessionWorthSaving() {
        // Backgrounding keeps the old session and the resume seek builds a new
        // one, so a sample reaching a torn-down session says nothing and must
        // not end playback.
        #expect(session(suspended: true, rebuiltGeneration: 7) == .ignore)
    }

    /// A rebuild is a seek, which needs a running demux loop. After
    /// cancellation there is none, so asking would swap a reported failure for
    /// a spinner.
    @Test func aFaultAfterPlaybackEndedAsksForNothing() {
        #expect(session(cancelled: true) == .tooLate)
        // Cancellation wins: samples draining from a torn-down decoder report
        // the session going with it.
        #expect(
            session(
                cancelled: true,
                suspended: true,
                recovering: true,
                background: true,
                rebuiltGeneration: 7
            ) == .tooLate
        )
    }

    @Test func demuxErrorsSayWhetherRedeliveryCouldHelp() {
        // Container and transport problems are what a server remux fixes; a
        // codec outside the envelope is not.
        #expect(DemuxError.openFailed("moov atom not found").cause == .delivery)
        #expect(DemuxError.seekFailed("invalid argument").cause == .delivery)
        #expect(DemuxError.unsupportedVideo("av1").cause == .undecodable)
    }

    @Test func aDamagedRunInAStreamThatDecodesIsDroppedNotJudged() {
        // A real film's shape: minutes of clean pictures, then 47 that
        // VideoToolbox rejects until the next keyframe.
        var state = PlaybackCorruptFramePolicy.State()
        for _ in 0..<4_000 { state.recordDecoded() }
        for _ in 0..<47 { #expect(absorbs(&state)) }
        for _ in 0..<PlaybackCorruptFramePolicy.recoveryFrames { state.recordDecoded() }
        // A later damaged run gets the whole allowance again.
        for _ in 0..<PlaybackCorruptFramePolicy.toleratedRun { #expect(absorbs(&state)) }
        #expect(state.dropped == 47 + PlaybackCorruptFramePolicy.toleratedRun)
    }

    @Test func aStreamThatFailsFromItsFirstPicturesStillReachesTheLadder() {
        var state = PlaybackCorruptFramePolicy.State()
        #expect(!absorbs(&state))
        for _ in 0..<(PlaybackCorruptFramePolicy.proofFrames - 1) { state.recordDecoded() }
        #expect(!absorbs(&state))
        state.recordDecoded()
        #expect(absorbs(&state))
    }

    @Test func aRunTooLongForOneDamagedGroupIsAVerdict() {
        var state = PlaybackCorruptFramePolicy.State()
        for _ in 0..<PlaybackCorruptFramePolicy.proofFrames { state.recordDecoded() }
        for _ in 0..<PlaybackCorruptFramePolicy.toleratedRun { #expect(absorbs(&state)) }
        #expect(!absorbs(&state))
        // Clean pictures between damaged ones do not close the run early.
        var interleaved = PlaybackCorruptFramePolicy.State()
        for _ in 0..<PlaybackCorruptFramePolicy.proofFrames { interleaved.recordDecoded() }
        var judged = false
        for _ in 0..<1_000 {
            guard absorbs(&interleaved) else { judged = true; break }
            interleaved.recordDecoded()
        }
        #expect(judged)
    }

    /// A seek, the viewer's or the engine's own recovery, must not turn the
    /// next damaged picture into a verdict on a stream that already decoded.
    @Test func aSeekKeepsTheStreamsProofButJudgesSoonerBeforeTheFirstPicture() {
        var state = PlaybackCorruptFramePolicy.State()
        for _ in 0..<4_000 { state.recordDecoded() }
        #expect(absorbs(&state))
        state.reset()
        for _ in 0..<PlaybackCorruptFramePolicy.proofFrames { #expect(absorbs(&state)) }
        #expect(!absorbs(&state))
        #expect(state.dropped == 1 + PlaybackCorruptFramePolicy.proofFrames)
    }

    @Test func onceTheNewSessionDecodesTheFullAllowanceReturns() {
        var state = PlaybackCorruptFramePolicy.State()
        for _ in 0..<PlaybackCorruptFramePolicy.proofFrames { state.recordDecoded() }
        state.reset()
        state.recordDecoded()
        for _ in 0..<PlaybackCorruptFramePolicy.toleratedRun { #expect(absorbs(&state)) }
        #expect(!absorbs(&state))
    }

    @Test func aSeekDoesNotProveAStreamThatNeverDecoded() {
        var state = PlaybackCorruptFramePolicy.State()
        for _ in 0..<(PlaybackCorruptFramePolicy.proofFrames - 1) { state.recordDecoded() }
        state.reset()
        #expect(!absorbs(&state))
    }

    /// The Apple TV's shape: 18 failures over 0.7 s, then clean pictures.
    @Test func aRendererPlaysThroughADamagedGroupOfPictures() {
        var state = PlaybackRendererDamagePolicy.State()
        for index in 0..<18 {
            #expect(playsThrough(&state, 5.25 + Double(index) * 0.042, 130 + index))
        }
        #expect(state.dropped == 18)
    }

    @Test func aRendererFailingFromItsFirstSamplesStillReachesTheLadder() {
        var state = PlaybackRendererDamagePolicy.State()
        #expect(!playsThrough(&state, 0.1, 3))
        #expect(!playsThrough(&state, 0.2, PlaybackRendererDamagePolicy.proofSamples - 1))
    }

    @Test func aRendererRunTooLongIsAVerdictAndAQuietGapClosesIt() {
        var state = PlaybackRendererDamagePolicy.State()
        let proof = PlaybackRendererDamagePolicy.proofSamples
        for index in 0..<PlaybackRendererDamagePolicy.toleratedRun {
            #expect(playsThrough(&state, Double(index) * 0.04, proof))
        }
        #expect(!playsThrough(&state, 12.1, proof))
        // Two quiet seconds later, a new run gets the whole allowance.
        #expect(playsThrough(&state, 12.1 + PlaybackRendererDamagePolicy.quietSeconds + 0.5, 0))
    }

    @Test func onlyADecodeFailureOverOnePicturesFaultIsRendererDamage() {
        func failure(code: Int, underlying: Int?) -> NSError {
            var info: [String: Any] = [:]
            if let underlying {
                info[NSUnderlyingErrorKey] = NSError(domain: NSOSStatusErrorDomain, code: underlying)
            }
            return NSError(domain: AVFoundationErrorDomain, code: code, userInfo: info)
        }
        let decodeFailed = AVError.Code.decodeFailed.rawValue
        #expect(SampleBufferPlayerEngine.isRendererFrameFault(failure(code: decodeFailed, underlying: -12909)))
        #expect(SampleBufferPlayerEngine.isRendererFrameFault(failure(code: decodeFailed, underlying: -12704)))
        #expect(!SampleBufferPlayerEngine.isRendererFrameFault(failure(code: decodeFailed, underlying: -12910)))
        #expect(!SampleBufferPlayerEngine.isRendererFrameFault(failure(code: decodeFailed, underlying: nil)))
        #expect(!SampleBufferPlayerEngine.isRendererFrameFault(failure(code: -11800, underlying: -12909)))
        #expect(!SampleBufferPlayerEngine.isRendererFrameFault(nil))
    }

    private func playsThrough(
        _ state: inout PlaybackRendererDamagePolicy.State,
        _ refusedSeconds: Double?,
        _ samplesSinceFlush: Int
    ) -> Bool {
        state.absorbs(refusedSeconds: refusedSeconds, samplesSinceFlush: samplesSinceFlush)
    }

    /// ADTS AAC, as MPEG-TS carries it, has no AudioSpecificConfig; handed
    /// to CoreAudio it never played and the clock waited on it forever.
    @Test func aacWithoutACodecConfigurationIsDecodedHere() {
        #expect(AudioDecodePolicy.requiresLocalPCM(
            codecID: AV_CODEC_ID_AAC, softwareVideoDecoded: false, hasCodecConfiguration: false
        ))
        #expect(!AudioDecodePolicy.requiresLocalPCM(
            codecID: AV_CODEC_ID_AAC, softwareVideoDecoded: false, hasCodecConfiguration: true
        ))
        // AC-3 and E-AC-3 carry their configuration in every frame.
        #expect(!AudioDecodePolicy.requiresLocalPCM(
            codecID: AV_CODEC_ID_AC3, softwareVideoDecoded: false, hasCodecConfiguration: false
        ))
        #expect(!AudioDecodePolicy.requiresLocalPCM(
            codecID: AV_CODEC_ID_EAC3, softwareVideoDecoded: true, hasCodecConfiguration: false
        ))
    }

    /// `#expect` cannot take a mutating call.
    private func absorbs(_ state: inout PlaybackCorruptFramePolicy.State) -> Bool {
        state.absorbsDamagedFrame()
    }

    @Test func aDemuxErrorReportsItsStageAndCodeAndNothingElse() {
        let opened = DemuxError.openFailed("moov atom not found", code: -1094995529).diagnosticDetail
        #expect(opened.stage == .open)
        #expect(opened.code == -1094995529)
        // No libavformat code means none in the report, not a zero a dashboard
        // groups on.
        #expect(DemuxError.seekFailed("demuxer not open").diagnosticDetail.code == nil)
    }
}
