import Libavutil
import Libswresample

/// Loudness and channel shaping for the audio the engine decodes.
///
/// While any of it is on, every audio track decodes to LPCM here, so AC-3,
/// E-AC-3 and AAC stop passing through compressed and Dolby Atmos is lost.
/// A host offering the setting should say so.
public nonisolated struct AudioShaping: Sendable, Equatable {
    /// The most channels the output carries. Anything wider is downmixed.
    public enum ChannelLimit: Int32, Sendable, CaseIterable {
        case stereo = 2
        case surround = 6
    }

    /// Quiet passages up and loud ones down, for late listening.
    public var nightMode: Bool
    /// The centre channel lifted over the rest. Stereo without a centre
    /// gets the speech band of what both channels share lifted instead.
    public var dialogueBoost: Bool
    public var channelLimit: ChannelLimit?

    public init(nightMode: Bool = false, dialogueBoost: Bool = false, channelLimit: ChannelLimit? = nil) {
        self.nightMode = nightMode
        self.dialogueBoost = dialogueBoost
        self.channelLimit = channelLimit
    }

    public static let off = AudioShaping()

    public var isActive: Bool { nightMode || dialogueBoost || channelLimit != nil }
}

/// The remix matrix for the dialogue boost: swresample's own downmix, with
/// the centre 3 dB up and every other channel 3 dB down.
nonisolated enum AudioShapingMatrix {
    static let centreGain = 2.0.squareRoot()
    static let otherGain = 1 / 2.0.squareRoot()
    /// swresample's `SWR_CH_MAX`. `swr_build_matrix2` scales all 64 rows of
    /// 64 whatever the layouts, so a matrix sized to the channels has it
    /// rewriting the heap past the end.
    static let stride = 64

    /// `matrix[input + stride * output]`, as `swr_set_matrix` reads it.
    /// Nil when there is no centre to lift, or nothing to lift it over, so
    /// swresample's default stands.
    static func coefficients(
        from input: UnsafePointer<AVChannelLayout>,
        to output: UnsafePointer<AVChannelLayout>,
        liftingCentre: Bool
    ) -> [Double]? {
        guard liftingCentre, input.pointee.nb_channels > 1 else { return nil }
        let centre = av_channel_layout_index_from_channel(input, AV_CHAN_FRONT_CENTER)
        guard centre >= 0 else { return nil }
        let inputCount = Int(input.pointee.nb_channels)
        let outputCount = Int(output.pointee.nb_channels)
        var matrix = [Double](repeating: 0, count: stride * stride)
        // The levels swresample defaults to. A float output is never
        // normalised there, so neither is it here: the limiter holds peaks.
        let status = swr_build_matrix2(
            input, output,
            1 / 2.0.squareRoot(), 1 / 2.0.squareRoot(), 0,
            Double(Int32.max), 1,
            &matrix, stride, AV_MATRIX_ENCODING_NONE, nil
        )
        guard status >= 0 else { return nil }
        for out in 0..<outputCount {
            for channel in 0..<inputCount {
                matrix[channel + stride * out] *= channel == Int(centre) ? centreGain : otherGain
            }
        }
        return matrix
    }
}
