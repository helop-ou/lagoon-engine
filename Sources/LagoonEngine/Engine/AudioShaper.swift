import Foundation

/// Applies `AudioShaping` in place to interleaved Float32 LPCM: the stereo
/// speech lift, the night-mode compressor, then a peak limiter.
///
/// Every stage reacts only to samples it has already seen, never ahead, so
/// shaping adds no latency and the clock has nothing to correct for.
nonisolated struct AudioShaper {
    static let nightThresholdDecibels: Float = -30
    static let nightRatio: Float = 4
    static let nightMakeupDecibels: Float = 10
    static let limiterCeiling: Float = powf(10, -1 / 20)

    private let channels: Int
    private let nightMode: Bool
    private let dialogueBoost: Bool
    /// Set per input: a source with a centre channel is lifted in the remix
    /// matrix instead.
    var liftsSpeechBand = false

    private let attack: Float
    private let release: Float
    private let limiterRelease: Float
    private var envelope: Float = 0
    private var limiterGain: Float = 1
    private var speechBand: Biquad

    init(shaping: AudioShaping, sampleRate: Int32, channels: Int) {
        self.channels = max(channels, 1)
        nightMode = shaping.nightMode
        dialogueBoost = shaping.dialogueBoost
        let rate = Float(max(sampleRate, 1))
        attack = Self.smoothing(seconds: 0.010, sampleRate: rate)
        release = Self.smoothing(seconds: 0.250, sampleRate: rate)
        limiterRelease = Self.smoothing(seconds: 0.050, sampleRate: rate)
        speechBand = Biquad(bandPassAt: 1_000, q: 0.7, sampleRate: rate)
    }

    mutating func reset() {
        envelope = 0
        limiterGain = 1
        speechBand.reset()
    }

    mutating func process(_ samples: UnsafeMutablePointer<Float>, frames: Int) {
        if dialogueBoost, liftsSpeechBand, channels == 2 {
            liftSpeechBand(samples, frames: frames)
        }
        if nightMode {
            compress(samples, frames: frames)
        }
        limit(samples, frames: frames)
    }

    /// Adds the speech band of the mid signal back to both channels, about
    /// 6 dB at 1 kHz. Sound panned to one side has little mid and stays.
    private mutating func liftSpeechBand(_ samples: UnsafeMutablePointer<Float>, frames: Int) {
        for frame in 0..<frames {
            let left = samples[frame * 2]
            let right = samples[frame * 2 + 1]
            let lift = speechBand.process((left + right) / 2)
            samples[frame * 2] = left + lift
            samples[frame * 2 + 1] = right + lift
        }
    }

    /// Feed-forward, linked across channels so the image does not shift.
    private mutating func compress(_ samples: UnsafeMutablePointer<Float>, frames: Int) {
        let slope = 1 - 1 / Self.nightRatio
        for frame in 0..<frames {
            let base = frame * channels
            let peak = Self.peak(samples + base, channels: channels)
            let coefficient = peak > envelope ? attack : release
            envelope = peak + coefficient * (envelope - peak)
            let level = 20 * log10f(max(envelope, 1e-9))
            let over = max(level - Self.nightThresholdDecibels, 0)
            let gain = powf(10, (Self.nightMakeupDecibels - over * slope) / 20)
            for channel in 0..<channels {
                samples[base + channel] *= gain
            }
        }
    }

    /// Instant attack, so no sample leaves above the ceiling.
    private mutating func limit(_ samples: UnsafeMutablePointer<Float>, frames: Int) {
        let ceiling = Self.limiterCeiling
        for frame in 0..<frames {
            let base = frame * channels
            let peak = Self.peak(samples + base, channels: channels)
            let needed: Float = peak > ceiling ? ceiling / peak : 1
            let recovered = 1 - (1 - limiterGain) * limiterRelease
            limiterGain = min(needed, recovered)
            guard limiterGain < 1 else { continue }
            for channel in 0..<channels {
                samples[base + channel] *= limiterGain
            }
        }
    }

    private static func peak(_ frame: UnsafeMutablePointer<Float>, channels: Int) -> Float {
        var peak: Float = 0
        for channel in 0..<channels {
            peak = max(peak, abs(frame[channel]))
        }
        return peak
    }

    /// The per-sample coefficient of a one-pole smoother with this time
    /// constant.
    private static func smoothing(seconds: Float, sampleRate: Float) -> Float {
        expf(-1 / (seconds * sampleRate))
    }
}

/// A second-order section, transposed direct form II.
nonisolated struct Biquad {
    private let b0, b1, b2, a1, a2: Float
    private var z1: Float = 0
    private var z2: Float = 0

    /// Unity gain at the centre frequency (the RBJ cookbook's band-pass with
    /// constant peak gain).
    init(bandPassAt frequency: Float, q: Float, sampleRate: Float) {
        let omega = 2 * Float.pi * frequency / sampleRate
        let alpha = sinf(omega) / (2 * q)
        let a0 = 1 + alpha
        b0 = alpha / a0
        b1 = 0
        b2 = -alpha / a0
        a1 = -2 * cosf(omega) / a0
        a2 = (1 - alpha) / a0
    }

    mutating func reset() {
        z1 = 0
        z2 = 0
    }

    mutating func process(_ input: Float) -> Float {
        let output = b0 * input + z1
        z1 = b1 * input - a1 * output + z2
        z2 = b2 * input - a2 * output
        return output
    }
}
