import CoreGraphics
import Foundation
import Testing
@testable import LagoonEngine

@Suite("Subtitle cue lifetime and lookup")
struct SubtitleStoreTests {
    @Test func expiredBitmapsReleaseWhilePlaybackContinues() throws {
        let store = SubtitleStore()
        let releases = BitmapReleases()

        // Many distinct providers expose retained image backing, which
        // Instruments' leak check cannot find.
        for index in 0..<250 {
            let start = Double(index * 2)
            store.add(try bitmapCue(start: start, end: start + 1, releases: releases))
            #expect(store.active(at: start).images.count == 1)
            #expect(store.active(at: start + 1).images.isEmpty)
            #expect(store.count == 0)
            #expect(releases.count == index + 1)
        }
    }

    @Test func displayedSnapshotOwnsItsImageOnlyUntilTheOverlayReplacesIt() throws {
        let store = SubtitleStore()
        let releases = BitmapReleases()
        store.add(try bitmapCue(start: 1, end: 2, releases: releases))
        var displayed: [SubtitleImage]? = store.active(at: 1).images

        withExtendedLifetime(displayed) {
            #expect(store.active(at: 2).images.isEmpty)
            #expect(store.count == 0)
            #expect(releases.count == 0)
        }
        displayed = nil
        #expect(releases.count == 1)
    }

    @Test func pruningPreservesOverlapsAndFutureCuesRegardlessOfInsertionOrder() {
        let store = SubtitleStore()
        store.add(cue("long", start: 1, end: 10))
        store.add(cue("future", start: 100, end: 101))
        store.add(cue("short", start: 2, end: 3))

        #expect(texts(store, at: 2) == ["long", "short"])
        #expect(texts(store, at: 3) == ["long"])
        #expect(store.count == 2)
        #expect(texts(store, at: 10).isEmpty)
        #expect(store.count == 1)
        #expect(texts(store, at: 100) == ["future"])
        #expect(texts(store, at: 101).isEmpty)
        #expect(store.count == 0)
    }

    @Test func openEndedCompositionsLiveUntilTheNextCompositionOrClear() throws {
        let store = SubtitleStore()
        let releases = BitmapReleases()
        store.add(try bitmapCue(start: 1, end: .infinity, releases: releases))
        #expect(store.active(at: 100).images.count == 1)
        #expect(releases.count == 0)

        // A clear decoded ahead of the clock closes the cue at its media time,
        // not early.
        store.closeOpenCues(at: 105)
        #expect(store.active(at: 104).images.count == 1)
        #expect(store.active(at: 105).images.isEmpty)
        #expect(releases.count == 1)

        store.add(cue("left", start: 110, end: .infinity))
        store.add(cue("right", start: 110, end: .infinity))
        store.add(cue("next", start: 115, end: .infinity))
        #expect(texts(store, at: 114) == ["left", "right"])
        #expect(texts(store, at: 115) == ["next"])
        #expect(store.count == 1)
        store.closeOpenCues(at: 120)
        #expect(texts(store, at: 120).isEmpty)
        #expect(store.count == 0)
    }

    @Test func embeddedSeekResetAcceptsRedemuxedCuesAtAnEarlierTime() {
        let store = SubtitleStore()
        store.add(cue("first pass", start: 1, end: 3))
        #expect(texts(store, at: 100).isEmpty)

        // A late decoder result between ticks is removed on the next refresh.
        store.add(cue("late", start: 20, end: 21))
        #expect(texts(store, at: 100).isEmpty)
        #expect(store.count == 0)
        store.add(cue("old future", start: 110, end: 115))
        store.resetForEmbeddedPlayback()
        store.add(cue("redemuxed", start: 1, end: 3))
        #expect(texts(store, at: 2) == ["redemuxed"])
        #expect(store.count == 1)
    }

    @Test func externalTracksRetainEarlierCuesAcrossForwardAndBackwardSeeks() {
        let store = SubtitleStore()
        store.replaceExternalTrack(with: [
            cue("future", start: 100, end: 105),
            cue("long", start: 1, end: 200),
            cue("left", start: 2, end: 3),
            cue("right", start: 2, end: 4),
        ])

        #expect(texts(store, at: 2) == ["long", "left", "right"])
        #expect(texts(store, at: 2) == ["long", "left", "right"])
        #expect(texts(store, at: 3) == ["long", "right"])
        #expect(texts(store, at: 150) == ["long"])
        #expect(texts(store, at: 250).isEmpty)
        #expect(texts(store, at: 102) == ["long", "future"])
        #expect(texts(store, at: 2) == ["long", "left", "right"])
        #expect(texts(store, at: 0).isEmpty)
        #expect(texts(store, at: 2) == ["long", "left", "right"])
        #expect(store.count == 4)
    }

    @Test func trackReplacementResetsCursorAndRejectsOldEmbeddedEvents() {
        let store = SubtitleStore()
        store.add(cue("embedded", start: 1, end: .infinity))
        store.replaceExternalTrack(with: [cue("external", start: 1, end: 100)])
        #expect(texts(store, at: 50) == ["external"])
        store.add(cue("old decoder", start: 51, end: 100))
        store.closeOpenCues(at: 52)
        #expect(texts(store, at: 53) == ["external"])

        store.replaceExternalTrack(with: [cue("replacement", start: 1, end: 100)])
        #expect(texts(store, at: 53) == ["replacement"])
        store.resetForEmbeddedPlayback()
        #expect(store.count == 0)
        store.add(cue("new embedded", start: 1, end: 3))
        #expect(texts(store, at: 2) == ["new embedded"])
    }

    @Test func demuxWritesAndDisplayReadsShareASynchronizedWindow() {
        let store = SubtitleStore()
        DispatchQueue.concurrentPerform(iterations: 1_000) { index in
            store.add(SubtitleCue(start: 1_000, end: 1_001, text: String(index), images: []))
            _ = store.active(at: 0)
        }
        #expect(store.count == 1_000)
        #expect(store.active(at: 1_000).textCues.count == 1_000)
        #expect(store.active(at: 1_001).textCues.isEmpty)
        #expect(store.count == 0)
    }

    private func cue(_ text: String, start: Double, end: Double) -> SubtitleCue {
        SubtitleCue(start: start, end: end, text: text, images: [])
    }

    private func texts(_ store: SubtitleStore, at seconds: Double) -> [String] {
        store.active(at: seconds).textCues.map(\.text)
    }

    private func bitmapCue(start: Double, end: Double, releases: BitmapReleases) throws -> SubtitleCue {
        let width = 64
        let height = 32
        let byteCount = width * height * 4
        let bytes = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 4)
        bytes.initializeMemory(as: UInt8.self, repeating: 255, count: byteCount)
        let info = Unmanaged.passRetained(releases).toOpaque()
        let provider = CGDataProvider(
            dataInfo: info,
            data: bytes,
            size: byteCount,
            releaseData: { info, data, _ in
                UnsafeMutableRawPointer(mutating: data).deallocate()
                if let info {
                    Unmanaged<BitmapReleases>.fromOpaque(info).takeRetainedValue().recordRelease()
                }
            }
        )
        if provider == nil {
            bytes.deallocate()
            Unmanaged<BitmapReleases>.fromOpaque(info).release()
        }
        let dataProvider = try #require(provider)
        let image = try #require(CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: dataProvider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent
        ))
        return SubtitleCue(
            start: start, end: end, text: nil,
            images: [SubtitleImage(image: image, rect: CGRect(x: 0, y: 0, width: 1, height: 1))]
        )
    }
}

/// CoreGraphics may release a provider on any thread; the lock keeps the
/// assertions race-free.
private nonisolated final class BitmapReleases: @unchecked Sendable {
    private let lock = NSLock()
    private var releases = 0

    var count: Int { lock.withLock { releases } }
    func recordRelease() { lock.withLock { releases += 1 } }
}
