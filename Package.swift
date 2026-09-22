// swift-tools-version:6.2

// Lagoon's playback engine and the native libraries it decodes with, as one
// package. They cannot be a nested package: SwiftPM does not resolve a path
// dependency inside a package fetched from a URL.
//
// Every native library is built here or vendored with its provenance; nothing
// is fetched at resolve time. The four FFmpeg libraries come from one configure
// (scripts/build-ffmpeg.py) without the network stack, since HTTP and
// certificate trust live in `FFmpegNetworkTransport`. That keeps them
// LGPL-2.1-or-later with no GnuTLS; see Artifacts/FFmpeg.README.md.

import PackageDescription

let package = Package(
    name: "LagoonEngine",
    platforms: [.iOS(.v26), .tvOS(.v26)],
    products: [
        .library(
            name: "LagoonEngine",
            targets: ["LagoonEngine"]
        ),
    ],
    targets: [
        .target(
            name: "LagoonEngine",
            dependencies: [
                "_LagoonFFmpeg",
                "LagoonPixelOps",
                "Libavcodec", "Libavformat", "Libavutil", "Libswresample",
                "Libdav1d", "Libuavs3d", "lcms2", "Libdovi",
            ],
            path: "Sources/LagoonEngine",
            swiftSettings: [
                // Default MainActor isolation, matching the host app.
                .defaultIsolation(MainActor.self),
                .swiftLanguageMode(.v5),
            ]
        ),
        .testTarget(
            name: "LagoonEngineTests",
            dependencies: ["LagoonEngine"],
            path: "Tests/LagoonEngineTests",
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .swiftLanguageMode(.v5),
            ]
        ),
        .target(
            name: "_LagoonFFmpeg",
            dependencies: [
                "LagoonPixelOps",
                "Libavcodec", "Libavformat", "Libavutil", "Libswresample",
                "Libdav1d", "Libuavs3d", "lcms2", "Libdovi",
            ],
            path: "Sources/_LagoonFFmpeg",
            linkerSettings: [
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Security"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("Metal"),
                .linkedFramework("VideoToolbox"),
                .linkedLibrary("bz2"),
                .linkedLibrary("iconv"),
                .linkedLibrary("expat"),
                .linkedLibrary("resolv"),
                .linkedLibrary("xml2"),
                .linkedLibrary("z"),
                .linkedLibrary("c++"),
            ]
        ),
        .target(
            name: "LagoonPixelOps",
            path: "Sources/LagoonPixelOps",
            publicHeadersPath: "include",
            cSettings: [
                // Xcode 26 enables coverage for package targets even when the
                // app's Release config disables it. These are per-pixel hot
                // loops, so turn it off here.
                .unsafeFlags(
                    ["-fno-profile-instr-generate", "-fno-coverage-mapping"],
                    .when(configuration: .release)
                ),
            ]
        ),
        .binaryTarget(
            name: "Libavcodec",
            // Rebuild/provenance: scripts/build-ffmpeg.py.
            path: "Artifacts/Libavcodec.xcframework"
        ),
        .binaryTarget(
            name: "Libavformat",
            // Rebuild/provenance: scripts/build-ffmpeg.py.
            path: "Artifacts/Libavformat.xcframework"
        ),
        .binaryTarget(
            name: "Libavutil",
            // Rebuild/provenance: scripts/build-ffmpeg.py.
            path: "Artifacts/Libavutil.xcframework"
        ),
        .binaryTarget(
            name: "Libswresample",
            // Rebuild/provenance: scripts/build-ffmpeg.py.
            path: "Artifacts/Libswresample.xcframework"
        ),
        // dav1d 1.5.4, built by scripts/build-dav1d.sh with its assembly kept.
        // mpvkit's build disabled the assembly, and AV1 then decoded at
        // 11.4 fps against the 23.976 a 4K episode needs on Apple TV.
        // Vendored: there is no upstream binary to point at.
        .binaryTarget(
            name: "Libdav1d",
            path: "Artifacts/Libdav1d.xcframework"
        ),
        // libdovi: the dolby_vision crate's C API (dovi_tool, MIT), to rewrite
        // a Dolby Vision profile 7 RPU as profile 8.1 in flight. Vendored from
        // superuser404notfound/LibDovi 2.1.0 (dolby_vision 3.4.0), static,
        // local symbols stripped. The tvOS simulator slice is arm64 only
        // (x86_64-apple-tvos is a tier-3 Rust target). Provenance:
        // Artifacts/Libdovi.README.md.
        .binaryTarget(
            name: "Libdovi",
            path: "Artifacts/Libdovi.xcframework"
        ),
        .binaryTarget(
            name: "lcms2",
            // Little CMS 2.17, MIT. Rebuild/provenance: scripts/build-lcms2.sh.
            path: "Artifacts/lcms2.xcframework"
        ),
        .binaryTarget(
            name: "Libuavs3d",
            // uavs3d, BSD-3-Clause, at a pinned upstream commit.
            // Rebuild/provenance: scripts/build-uavs3d.sh.
            path: "Artifacts/Libuavs3d.xcframework"
        ),
    ]
)
