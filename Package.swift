// swift-tools-version:6.2

// Lagoon's playback engine, and the FFmpeg binaries it decodes with, as one
// package.
//
// The native libraries used to live in a separate `LagoonFFmpeg` package
// inside the app repository. They are folded in here rather than kept as a
// nested package because SwiftPM does not resolve a path dependency declared
// inside a package that was itself fetched from a URL: a consumer adding
// lagoon-engine as a dependency would fail to resolve. One package, many
// targets, one product.
//
// Every native library is built by this repository, or vendored here with its
// provenance, and nothing is fetched at resolve time. The four FFmpeg
// libraries come from one configure (scripts/build-ffmpeg.py) without the
// network stack: HTTP goes through URLSession in `FFmpegNetworkTransport`,
// which is also where certificate trust lives, so GnuTLS and the
// --enable-version3 its licence required are gone, and all four are
// LGPL-2.1-or-later. Artifacts/FFmpeg.README.md has the detail.

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
                // Matches the app's isolation model, so types keep the
                // meaning they had before the move.
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
                // Xcode 26 enables coverage for Swift-package targets even
                // when the containing app's Release target disables it.
                // These are the per-pixel hot loops, so make the Release
                // override explicit at the package boundary.
                .unsafeFlags(
                    ["-fno-profile-instr-generate", "-fno-coverage-mapping"],
                    .when(configuration: .release)
                ),
            ]
        ),
        .binaryTarget(
            name: "Libavcodec",
            // Rebuild/provenance: scripts/build-ffmpeg.py, which builds all
            // four FFmpeg libraries together.
            path: "Artifacts/Libavcodec.xcframework"
        ),
        .binaryTarget(
            name: "Libavformat",
            // Rebuild/provenance: scripts/build-ffmpeg.py, which builds all
            // four FFmpeg libraries together.
            path: "Artifacts/Libavformat.xcframework"
        ),
        .binaryTarget(
            name: "Libavutil",
            // Rebuild/provenance: scripts/build-ffmpeg.py, which builds all
            // four FFmpeg libraries together.
            path: "Artifacts/Libavutil.xcframework"
        ),
        .binaryTarget(
            name: "Libswresample",
            // Rebuild/provenance: scripts/build-ffmpeg.py, which builds all
            // four FFmpeg libraries together.
            path: "Artifacts/Libswresample.xcframework"
        ),
        // This repository also builds dav1d itself. mpvkit's dav1d is
        // compiled with -Denable_asm=false, to silence an Xcode 15 linker
        // warning about assembled objects carrying no platform load command,
        // so every AV1 frame ran dav1d's portable C path: 11.4 fps against
        // the 23.976 a 4K HDR10+ episode needs, on an Apple TV. Same dav1d
        // 1.5.4, same headers, same public API, built by
        // scripts/build-dav1d.sh with the assembly kept and the warning
        // fixed properly by passing -target to the assembler.
        //
        // Vendored rather than fetched: there is nothing upstream to point
        // at, and a URL that has to outlive the library is a worse dependency
        // than eight megabytes in the repository.
        .binaryTarget(
            name: "Libdav1d",
            path: "Artifacts/Libdav1d.xcframework"
        ),
        // libdovi: the dolby_vision crate's C API (dovi_tool, MIT), for
        // rewriting a Dolby Vision profile 7 RPU into profile 8.1 while the
        // packet is in flight. Vendored from superuser404notfound/
        // LibDovi 2.1.0 (dolby_vision 3.4.0), iOS/tvOS/macOS slices only,
        // static libraries stripped of local symbols. The tvOS simulator slice
        // is arm64 only: x86_64-apple-tvos is a tier-3 Rust target, so the
        // project excludes x86_64 for that SDK. Rebuild recipe and provenance:
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
