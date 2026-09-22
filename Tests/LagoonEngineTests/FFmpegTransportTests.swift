import Foundation
import Libavcodec
import Libavformat
import Libavutil
import Testing
@testable import LagoonEngine

@Suite("Native FFmpeg transport", .serialized)
struct FFmpegTransportTests {
    /// libavformat is now repo-built without its network stack:
    /// every network fetch must go through `FFmpegNetworkTransport`'s
    /// URLSession-backed io_open, never a native protocol. This fails until
    /// the rebuilt library lands; that is expected and wanted.
    @Test func nativeNetworkingIsCompiledOut() throws {
        #expect(avio_protocol_get_class("http") == nil)
        #expect(avio_protocol_get_class("tls") == nil)
        let forbidden: Set<String> = ["http", "https", "tcp", "tls"]
        var opaque: UnsafeMutableRawPointer?
        var sawFile = false
        while let entry = avio_enum_protocols(&opaque, 0) {
            let name = String(cString: entry)
            #expect(!forbidden.contains(name), "native networking protocol '\(name)' is still linked in")
            if name == "file" { sawFile = true }
        }
        #expect(sawFile, "avio_enum_protocols should still yield the file protocol")
    }

    @Test func nativeOpenPreservesParentCancellation() throws {
        let transport = FFmpegNetworkTransport(isInterrupted: { true })
        var io: UnsafeMutablePointer<AVIOContext>?
        let result = "https://127.0.0.1:9/body".withCString { url in
            transport.open(context: nil, output: &io, url: url, flags: AVIO_FLAG_READ, options: nil)
        }
        #expect(result == ffmpegErrorExit)
        #expect(io == nil)
    }

    // Run scripts/test-ffmpeg-tls.py for controlled certificates, HTTP logs and
    // simulator-only trust roots. Ordinary unit runs still check the binary's
    // default, without depending on network access or third-party servers.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LAGOON_TLS_FIXTURES"] != nil))
    func certificateAndNestedRequestMatrix() async throws {
        let base = try #require(ProcessInfo.processInfo.environment["LAGOON_TLS_FIXTURES"])
        let (data, _) = try await URLSession.shared.data(from: #require(URL(string: base + "/fixtures")))
        let cases = try JSONDecoder().decode([Fixture].self, from: data)
        #expect(cases.count >= 20)
        for fixture in cases {
            let result = fixture.hls ? readHLS(fixture.url) : readNative(fixture)
            // Each valid HLS fixture has three one-second AAC segments. This
            // catches failures after the initial segment, including keepalive.
            let completed = fixture.hls ? result >= 120 : result > 0
            #expect(completed == fixture.allowed, "\(fixture.name): read result \(result)")
        }
        let (report, _) = try await URLSession.shared.data(from: #require(URL(string: base + "/report")))
        let violations = try JSONDecoder().decode([String].self, from: report)
        #expect(violations.isEmpty, "HTTP requests reached invalid TLS peers: \(violations)")
    }

    private nonisolated struct Fixture: Decodable {
        let name: String
        let url: String
        let allowed: Bool
        let hls: Bool
        let enforce: Bool
        let reconnect: Bool
    }

    /// Scopes a synthetic credential header to a fixture URL's own origin,
    /// exactly what `JellyfinClient.mediaRequestAuthorization()` does for
    /// the real server — so the `api_key` query item every fixture URL
    /// carries is stripped before URLSession ever sees it. CFNetwork logs a
    /// failed task's full URL (`NSErrorFailingURLKey`) into the unified
    /// log, which is what `test-ffmpeg-tls.py`'s "token appeared in
    /// test.log" guard checks for; leaving the token in the query here
    /// would make every invalid-peer fixture fail that guard.
    private nonisolated static func authorization(for urlString: String) -> MediaRequestAuthorization? {
        guard let url = URL(string: urlString), let scheme = url.scheme, let host = url.host else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = url.port
        guard let origin = components.url else { return nil }
        return MediaRequestAuthorization(
            origin: origin,
            headerName: "Authorization",
            headerValue: #"MediaBrowser Token="synthetic-tls-test-header""#,
            queryNames: ["api_key"]
        )
    }

    private nonisolated func readNative(_ fixture: Fixture) -> Int32 {
        let transport = FFmpegNetworkTransport(isInterrupted: { false }, authorization: Self.authorization(for: fixture.url))
        var io: UnsafeMutablePointer<AVIOContext>?
        var options: OpaquePointer?
        av_dict_set(&options, "rw_timeout", "5000000", 0)
        if fixture.enforce {
            // A caller cannot accidentally weaken the application policy —
            // there is no longer an unpoliced avio_open2 fallback to escape
            // through, so these attempts are expected to have no effect.
            av_dict_set(&options, "tls_verify", "0", 0)
            av_dict_set(&options, "verifyhost", "wrong.invalid", 0)
        }
        if fixture.reconnect {
            av_dict_set(&options, "reconnect", "1", 0)
            av_dict_set(&options, "reconnect_streamed", "1", 0)
            av_dict_set(&options, "reconnect_delay_max", "1", 0)
            av_dict_set(&options, "reconnect_max_retries", "1", 0)
        }
        defer {
            if io != nil { _ = transport.close(io) }
            av_dict_free(&options)
        }
        let result = fixture.url.withCString { url in
            transport.open(context: nil, output: &io, url: url, flags: AVIO_FLAG_READ, options: &options)
        }
        guard result >= 0, let io else { return result }
        var bytes = [UInt8](repeating: 0, count: 4096)
        var total: Int32 = 0
        while total < 65_536 {
            let count = avio_read(io, &bytes, Int32(bytes.count))
            if count <= 0 { break }
            total += count
        }
        // Reconnect fixtures advertise 64 KiB, then drop after 8 KiB. A valid
        // reconnect must finish; a changed invalid certificate must stop it.
        return fixture.reconnect && total != 65_536 ? -1 : total
    }

    private nonisolated func readHLS(_ url: String) -> Int32 {
        let transport = FFmpegNetworkTransport(isInterrupted: { false }, authorization: Self.authorization(for: url))
        defer { transport.closeAll() }
        guard let allocated = avformat_alloc_context() else { return -12 }
        transport.install(on: allocated)
        allocated.pointee.interrupt_callback = AVIOInterruptCB(callback: { _ in 0 }, opaque: nil)
        var context: UnsafeMutablePointer<AVFormatContext>? = allocated
        var options: OpaquePointer?
        av_dict_set(&options, "rw_timeout", "5000000", 0)
        // Leave HLS native persistent connections enabled, as in production.
        defer {
            avformat_close_input(&context)
            av_dict_free(&options)
        }
        let openResult = avformat_open_input(&context, url, nil, &options)
        guard openResult >= 0, let context else { return openResult }
        guard avformat_find_stream_info(context, nil) >= 0 else { return -1 }
        guard let packet = av_packet_alloc() else { return -12 }
        var packetToFree: UnsafeMutablePointer<AVPacket>? = packet
        defer { av_packet_free(&packetToFree) }
        var packets: Int32 = 0
        while packets < 500 {
            if av_read_frame(context, packet) < 0 { break }
            packets += 1
            av_packet_unref(packet)
        }
        return packets
    }
}
