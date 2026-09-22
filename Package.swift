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
// libavformat is built by this repository without its network stack
// (scripts/build-ffmpeg-format.py): HTTP goes through URLSession in
// `FFmpegNetworkTransport`, which is also where certificate trust lives, so
// the GnuTLS/GMP/nettle/hogweed static libraries — and the --enable-version3
// that GnuTLS's license required — are gone, making the repo-built
// libavformat LGPL-2.1-or-later. The three MPVKit binaries still carry
// upstream's version3 election until they are rebuilt here too.

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
            url: "https://github.com/mpvkit/MPVKit/releases/download/1.0.0/Libavcodec.xcframework.zip",
            checksum: "136e432919a8a7b5b80155c68e9dc91b0ef3ae6623970b87bb8bd96a452543cf"
        ),
        .binaryTarget(
            name: "Libavformat",
            // Same FFmpeg release, built with networking compiled
            // out (--disable-network --disable-protocols, file/data only).
            // Rebuild/provenance: scripts/build-ffmpeg-format.py.
            path: "Artifacts/Libavformat.xcframework"
        ),
        .binaryTarget(
            name: "Libavutil",
            url: "https://github.com/mpvkit/MPVKit/releases/download/1.0.0/Libavutil.xcframework.zip",
            checksum: "5dc251c8807c501982edfb0bc9bddfee4148733142d6ebb947738c60fb3bf8d8"
        ),
        .binaryTarget(
            name: "Libswresample",
            url: "https://github.com/mpvkit/MPVKit/releases/download/1.0.0/Libswresample.xcframework.zip",
            checksum: "d5c36acf2ff944e15706f4b7bfbf18bb1993ffc5b446c9f67f1aa79de5441f15"
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
            url: "https://github.com/mpvkit/lcms2-build/releases/download/2.17.0/lcms2.xcframework.zip",
            checksum: "dc0dce0606f6ab6841a8ec5a6bd4448e2f3ef00661a050460f806c9393dc6982"
        ),
        .binaryTarget(
            name: "Libuavs3d",
            url: "https://github.com/mpvkit/libuavs3d-build/releases/download/1.2.1-fix/Libuavs3d.xcframework.zip",
            checksum: "bd5256081486d16c51c868d755bf70266c424b54c895269580de44ec6707f789"
        ),
    ]
)
