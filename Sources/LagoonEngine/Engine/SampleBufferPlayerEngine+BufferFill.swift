import Foundation
import os

/// Proactive cache fill, which the engine runs for itself.
///
/// Starts once the first cushion is presented and fetches 1 MiB at a time.
/// `PlaybackFillPolicy` paces it from the cached media ahead of the
/// playhead, backs off after a failed fetch, and yields the link after a
/// stall. Foreground playback always has priority, not by URLSession hints.
extension SampleBufferPlayerEngine {
    func publishBufferState(_ metrics: PlaybackCacheMetrics?) {
        bufferState = metrics?.bufferState ?? .empty
    }

    /// Starts, or restarts, the fill loop for the session prepared earlier.
    /// Not while a successor is warming: one proactive download at a time.
    func startBufferFill() {
        bufferFillTask?.cancel()
        bufferFillTask = nil
        guard successorWarmTask == nil,
              let session = cacheSessionForFill,
              session.directScope != nil else {
            publishBufferState(cacheSessionForFill?.metrics)
            return
        }
        let generation = UUID()
        bufferFillGeneration = generation
        bufferFillTask = Task { [weak self] in
            // Clear the handle so a resume can restart, unless replaced.
            defer {
                if let self, self.bufferFillGeneration == generation {
                    self.bufferFillTask = nil
                }
            }
            do {
                try await Task.sleep(for: .seconds(PlaybackFillPolicy.warmupSeconds))
            } catch {
                return
            }
            guard let self else { return }
            var policy = PlaybackFillPolicy()
            var observedStalls = self.stallCount

            // Only the pre-fetch snapshot consumes a stall, so one that lands
            // mid-fetch still triggers the cooldown on the next pass.
            @MainActor func snapshot(
                _ metrics: PlaybackCacheMetrics,
                consumingStall: Bool = true
            ) -> PlaybackFillPolicy.Snapshot {
                let newStall = self.stallCount > observedStalls
                if consumingStall { observedStalls = self.stallCount }
                return .init(
                    isPaused: self.isPaused,
                    isBuffering: self.isBuffering,
                    newStall: newStall,
                    aheadSeconds: PlaybackFillPolicy.aheadSeconds(
                        cachedBytesAhead: metrics.cachedBytesAheadOfPlayhead,
                        contentLength: metrics.contentLength,
                        durationSeconds: self.duration
                    ),
                    averageBytesPerSecond: PlaybackFillPolicy.averageBytesPerSecond(
                        contentLength: metrics.contentLength,
                        durationSeconds: self.duration
                    ),
                    playbackRate: self.rate,
                    isWindowed: metrics.isWindowed,
                    bufferedFraction: metrics.bufferedFraction
                )
            }

            while !Task.isCancelled {
                guard self.cacheSessionForFill === session,
                      PlaybackCacheOwner.coordinator.current === session else { return }

                let before = session.metrics
                self.publishBufferState(before)
                switch policy.beforeFetch(snapshot(before)) {
                case .stop:
                    return
                case .wait(let seconds):
                    do {
                        try await Task.sleep(for: .seconds(seconds))
                    } catch {
                        return
                    }
                    continue
                case .fetch:
                    break
                }

                let outcome = await session.prefetchNextChunk()
                guard !Task.isCancelled,
                      self.cacheSessionForFill === session,
                      PlaybackCacheOwner.coordinator.current === session else { return }
                let after = session.metrics
                self.publishBufferState(after)
                os_signpost(
                    .event,
                    log: PlaybackPerformance.log,
                    name: "Playback Buffer Progress",
                    signpostID: self.performanceSignpostID,
                    "cachedMB=%{public}.1f totalMB=%{public}.1f prefixFraction=%{public}.3f ranges=%{public}d playheadPrefetches=%{public}d stalls=%{public}d aheadMB=%{public}.1f outcome=%{public}s",
                    Double(after.cachedBytes) / 1_048_576,
                    Double(after.contentLength ?? 0) / 1_048_576,
                    after.bufferedFraction ?? -1,
                    after.bufferedRanges.count,
                    after.playheadPrefetchCount,
                    self.stallCount,
                    Double(after.cachedBytesAheadOfPlayhead) / 1_048_576,
                    String(describing: outcome)
                )
                switch policy.afterFetch(outcome, snapshot(after, consumingStall: false)) {
                case .stop:
                    return
                case .wait(let seconds):
                    do {
                        try await Task.sleep(for: .seconds(seconds))
                    } catch {
                        return
                    }
                case .fetch:
                    continue
                }
            }
        }
    }

    /// Stops filling, leaving what is already cached alone.
    func suspendBufferFillInternal() {
        bufferFillTask?.cancel()
        bufferFillTask = nil
    }

    // MARK: - Successor warm-up

    /// Fetches up to 8 MiB in 1 MiB requests, with the fill loop's stall
    /// backoff and pacing. A failed chunk ends it rather than retrying: it
    /// must never hold the link during the handoff.
    func startSuccessorWarm(_ session: PlaybackCacheSession) {
        successorWarmTask?.cancel()
        guard session.directScope != nil else {
            successorWarmTask = nil
            return
        }
        let generation = UUID()
        successorWarmGeneration = generation
        successorWarmTask = Task { [weak self] in
            defer {
                if let self, self.successorWarmGeneration == generation {
                    self.successorWarmTask = nil
                }
            }
            let startingBytes = session.metrics.contiguousCachedBytes
            guard let self else { return }
            var observedStalls = self.stallCount
            while !Task.isCancelled,
                  session.metrics.contiguousCachedBytes - startingBytes < 8 * 1_024 * 1_024 {
                guard PlaybackCacheOwner.coordinator.next === session else { return }
                if self.isBuffering || self.stallCount > observedStalls {
                    observedStalls = self.stallCount
                    do {
                        try await Task.sleep(for: .seconds(10))
                    } catch {
                        return
                    }
                    continue
                }
                guard case .fetched(_, let requestSeconds) = await session.prefetchNextChunk() else { return }
                guard !Task.isCancelled else { return }
                if !self.isPaused {
                    let measured = max(requestSeconds, PlaybackFillPolicy.minimumMeasuredRequestSeconds)
                    do {
                        try await Task.sleep(for: .seconds(min(
                            measured * PlaybackFillPolicy.relaxedPacingMultiplier,
                            PlaybackFillPolicy.relaxedPacingCapSeconds
                        )))
                    } catch {
                        return
                    }
                }
            }
        }
    }

    func stopSuccessorWarm() {
        successorWarmTask?.cancel()
        successorWarmTask = nil
    }
}
