#!/usr/bin/env bash
#
# Builds dav1d as an xcframework for Lagoon, with its arm64 assembly enabled.
#
# Why this exists: Lagoon used to take dav1d from
# mpvkit/libdav1d-build, whose recipe passes
#
#     -Denable_asm=false   // disable "No platform load command found" warning after xcode 15
#
# so every AV1 frame ran dav1d's portable C path. On an Apple TV that measured
# 11.4 fps against the 23.976 a 4K HDR10+ episode needs. The warning it was
# silencing is real but cosmetic: meson assembles dav1d's .S files with the C
# compiler, and without an explicit -target those objects carry no platform
# load command. Passing -target to the assembler fixes the warning properly and
# keeps the SIMD, which is what this script does.
#
#   scripts/build-dav1d.sh                     # build and install into the package
#   scripts/build-dav1d.sh --output /tmp/out   # build somewhere else
#   scripts/build-dav1d.sh --verify-only <xcframework>
#
# Requires meson and ninja (brew install meson ninja).
#
# The simulator and macOS slices are fat arm64 + x86_64, because a
# `generic/platform=tvOS Simulator` build compiles both and refuses to link
# against a slice carrying only one. arm64 is built with assembly and x86_64
# is not, which is deliberate:
#
#   * arm64 is every Apple TV, every iPhone, and the simulator on an Apple
#     silicon Mac. It is the entire point of this script, and the check below
#     fails the build if its assembly ever goes missing again.
#   * x86_64 is reachable only from a simulator on an Intel Mac. Its assembly
#     comes from nasm, which cannot emit a platform load command, so every
#     clean simulator link would print 46 "no platform load command" warnings
#     for code that cannot run on any device and never runs on this project's
#     hardware at all.
#
# That is the same trade upstream made, and it is only defensible because it
# is scoped to an architecture that never ships. Upstream made it for arm64
# as well, which is what cost a factor of ten on the device.
#
set -euo pipefail

DAV1D_VERSION="1.5.4"
DAV1D_REPO="https://code.videolan.org/videolan/dav1d.git"
# Matches the app's own deployment targets; the artifact cannot be used below
# these.
TVOS_MIN="26.0"
IOS_MIN="26.0"
MACOS_MIN="14.0"

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output="$root/Packages/LagoonFFmpeg/Artifacts"
work=""
verify_only=""

usage() { sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --output) output="$2"; shift 2 ;;
        --work-dir) work="$2"; shift 2 ;;
        --version) DAV1D_VERSION="$2"; shift 2 ;;
        --verify-only) verify_only="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "unknown argument: $1" >&2; usage ;;
    esac
done

# The check that must never stop being run. A dav1d without these symbols
# still decodes every file correctly, just about ten times slower, so nothing
# fails and nothing looks wrong until someone measures a 4K stream on a device
# with two performance cores. That is how this shipped in the first place.
verify_asm() {
    local framework="$1" failures=0
    echo "== verifying assembly is present =="
    while IFS= read -r binary; do
        local slice
        slice="$(basename "$(dirname "$(dirname "$binary")")")"
        for arch in $(lipo -archs "$binary" 2>/dev/null); do
            local count
            # x86_64 carries no assembly on purpose; see the header.
            if [ "$arch" != "arm64" ]; then
                printf '   %-34s %-7s C only, by design\n' "$slice" "$arch"
                continue
            fi
            count="$(nm -arch "$arch" "$binary" 2>/dev/null | grep -ci "neon" || true)"
            printf '   %-34s %-7s %s NEON symbols\n' "$slice" "$arch" "$count"
            if [ "$count" -lt 100 ]; then
                echo "   ERROR: $slice/$arch has no assembly - this is the C fallback path" >&2
                failures=$((failures + 1))
            fi
        done
    done < <(find "$framework" -name Libdav1d -type f)
    [ "$failures" -eq 0 ] || { echo "verification failed" >&2; exit 1; }
    echo "   every arm64 slice carries assembly"
}

if [ -n "$verify_only" ]; then
    verify_asm "$verify_only"
    exit 0
fi

for tool in meson ninja xcodebuild git; do
    command -v "$tool" >/dev/null || { echo "error: $tool is required" >&2; exit 1; }
done

if [ -z "$work" ]; then
    work="$(mktemp -d "${TMPDIR:-/tmp}/dav1d-build.XXXXXX")"
    trap 'rm -rf "$work"' EXIT
fi
mkdir -p "$work"

src="$work/dav1d"
if [ ! -d "$src" ]; then
    echo "== cloning dav1d $DAV1D_VERSION =="
    git clone --depth 1 --branch "$DAV1D_VERSION" "$DAV1D_REPO" "$src"
fi

# group | sdk | arch | clang target triple | platform name for Info.plist
#
# One build per architecture; architectures sharing a group are lipo'd into one
# fat framework, which is what an xcframework slice is.
builds=(
    "tvos|appletvos|arm64|arm64-apple-tvos${TVOS_MIN}|AppleTVOS"
    "tvos-simulator|appletvsimulator|arm64|arm64-apple-tvos${TVOS_MIN}-simulator|AppleTVSimulator"
    "tvos-simulator|appletvsimulator|x86_64|x86_64-apple-tvos${TVOS_MIN}-simulator|AppleTVSimulator"
    "ios|iphoneos|arm64|arm64-apple-ios${IOS_MIN}|iPhoneOS"
    "ios-simulator|iphonesimulator|arm64|arm64-apple-ios${IOS_MIN}-simulator|iPhoneSimulator"
    "ios-simulator|iphonesimulator|x86_64|x86_64-apple-ios${IOS_MIN}-simulator|iPhoneSimulator"
    # Lagoon never runs on macOS, but SwiftPM resolves this package for the
    # host when Xcode indexes it, and a missing slice surfaces there as a
    # package error.
    "macos|macosx|arm64|arm64-apple-macos${MACOS_MIN}|MacOSX"
    "macos|macosx|x86_64|x86_64-apple-macos${MACOS_MIN}|MacOSX"
)

declare -A group_platform=()
declare -a group_order=()
declare -a group_libs=()

for entry in "${builds[@]}"; do
    IFS='|' read -r group sdk arch triple platform <<< "$entry"
    sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
    build="$work/build-$group-$arch"
    prefix="$work/install-$group-$arch"
    rm -rf "$build" "$prefix"

    case "$arch" in
        arm64) cpu_family="aarch64"; cpu="aarch64"; asm="true" ;;
        x86_64) cpu_family="x86_64"; cpu="x86_64"; asm="false" ;;
        *) echo "unknown arch $arch" >&2; exit 1 ;;
    esac

    # -target is the whole point: it is what stamps the platform load command
    # into the objects meson assembles from dav1d's .S files, which is the
    # warning upstream silenced by throwing away the assembly instead.
    cat > "$work/cross-$group-$arch.ini" <<CROSS
[binaries]
c = ['clang', '-target', '$triple', '-isysroot', '$sysroot']
cpp = ['clang++', '-target', '$triple', '-isysroot', '$sysroot']
ar = '$(xcrun --sdk "$sdk" --find ar)'
strip = '$(xcrun --sdk "$sdk" --find strip)'

[built-in options]
c_args = ['-target', '$triple', '-isysroot', '$sysroot', '-fno-common']
c_link_args = ['-target', '$triple', '-isysroot', '$sysroot']

[host_machine]
system = 'darwin'
subsystem = '${sdk}'
kernel = 'xnu'
cpu_family = '$cpu_family'
cpu = '$cpu'
endian = 'little'
CROSS

    echo "== building $group $arch ($triple) =="
    meson setup "$build" "$src" \
        --cross-file "$work/cross-$group-$arch.ini" \
        --prefix "$prefix" \
        --buildtype release \
        --default-library static \
        -Denable_asm=$asm \
        -Denable_tests=false \
        -Denable_tools=false \
        -Denable_examples=false \
        -Dxxhash_muxer=disabled \
        > "$work/setup-$group-$arch.log" 2>&1 \
        || { tail -40 "$work/setup-$group-$arch.log" >&2; exit 1; }

    ninja -C "$build" > "$work/ninja-$group-$arch.log" 2>&1 \
        || { tail -40 "$work/ninja-$group-$arch.log" >&2; exit 1; }
    ninja -C "$build" install > /dev/null 2>&1

    if [ -z "${group_platform[$group]:-}" ]; then
        group_platform[$group]="$platform"
        group_order+=("$group")
    fi
    group_libs+=("$group|$prefix/lib/libdav1d.a")
done

frameworks=()
for group in "${group_order[@]}"; do
    platform="${group_platform[$group]}"
    libs=()
    for pair in "${group_libs[@]}"; do
        [ "${pair%%|*}" = "$group" ] && libs+=("${pair#*|}")
    done

    # Same static-framework shape the previous artifact used, so the module
    # name and header paths _LagoonFFmpeg builds against do not move.
    fw="$work/frameworks/$group/Libdav1d.framework"
    mkdir -p "$fw/Headers" "$fw/Modules"
    if [ "${#libs[@]}" -gt 1 ]; then
        lipo -create "${libs[@]}" -output "$fw/Libdav1d"
    else
        cp "${libs[0]}" "$fw/Libdav1d"
    fi
    cp -R "$work/install-$group-arm64/include/dav1d" "$fw/Headers/"
    cat > "$fw/Modules/module.modulemap" <<'MODULE'
framework module Libdav1d [system] {
    umbrella "."
    export *
}
MODULE
    # MinimumOSVersion is deliberately above any OS that exists, which is
    # what every sibling artifact in this package declares and what App Store
    # validation requires (ITMS-90208). The check is "the app's minimum must
    # not exceed the framework's", and Xcode builds a stub dylib per binary
    # target using exactly this value, so a framework declaring the app's own
    # minimum sits on the boundary and is rejected: build 74 was.
    #
    # It has no runtime meaning. The stub never loads - dav1d is a static
    # archive linked into the app binary - and putting the value out of reach
    # of any real OS also makes this immune to future deployment-target bumps.
    # The deployment targets above still apply to the code itself, through
    # -target, which is what actually has to be right.
    min="100.0"
    cat > "$fw/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>Libdav1d</string>
    <key>CFBundleIdentifier</key><string>ee.helop.Libdav1d</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>Libdav1d</string>
    <key>CFBundlePackageType</key><string>FMWK</string>
    <key>CFBundleShortVersionString</key><string>$DAV1D_VERSION</string>
    <key>CFBundleSignature</key><string>????</string>
    <key>CFBundleSupportedPlatforms</key><array><string>$platform</string></array>
    <key>CFBundleVersion</key><string>$DAV1D_VERSION</string>
    <key>MinimumOSVersion</key><string>$min</string>
    <key>NSPrincipalClass</key><string></string>
</dict>
</plist>
PLIST
    frameworks+=(-framework "$fw")
done

echo "== assembling the xcframework =="
mkdir -p "$output"
rm -rf "$output/Libdav1d.xcframework"
xcodebuild -create-xcframework "${frameworks[@]}" \
    -output "$output/Libdav1d.xcframework" > /dev/null

verify_asm "$output/Libdav1d.xcframework"
echo
echo "dav1d $DAV1D_VERSION -> $output/Libdav1d.xcframework"
du -sh "$output/Libdav1d.xcframework"
