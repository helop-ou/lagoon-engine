#!/usr/bin/env bash
#
# Builds uavs3d, the AVS3 decoder libavcodec wraps as `libuavs3d`, as an
# xcframework with its arm64 assembly and 10-bit decoding.
#
#   scripts/build-uavs3d.sh                     # build and install into the package
#   scripts/build-uavs3d.sh --output /tmp/out   # build somewhere else
#   scripts/build-uavs3d.sh --verify-only <xcframework>
#
# Requires only Xcode. Source: upstream's repository at a pinned commit,
# fetched as a tarball and SHA-256 checked. uavs3d has tagged nothing since
# 1.2, and this is the commit MPVKit's libuavs3d-build 1.2.1-fix used.
#
# Upstream's CMakeLists is a flat source list with one define per architecture
# and COMPILE_10BIT, so this compiles the same list with clang directly. If
# upstream's list changes, this one must follow.
#
# As with dav1d, simulator and macOS slices are fat arm64 + x86_64 and only
# arm64 is checked for assembly. On x86_64 upstream's platform test never
# selects SSE/AVX2 with Apple's clang (it looks for __MACOSX__, __linux__ or
# __unix__), so x86_64 runs the C path, as the previous artifact did.
#
#
set -euo pipefail

UAVS3D_COMMIT="0e20d2c291853f196c68922a264bcd8471d75b68"
UAVS3D_URL="https://codeload.github.com/uavs3/uavs3d/tar.gz/$UAVS3D_COMMIT"
UAVS3D_SHA256="1c1eb778b6080bc01493180ea7ae671c6444ce3aa760b5d021ba882eb0f9e3a0"
# version.sh derives these from a git checkout, which a tarball is not: 1.2
# is hard-coded in that script, and 89 is the commit count at the pin.
UAVS3D_VERSION="1.2.89"
# Matches the engine's deployment targets; the artifact cannot be used below
# them.
TVOS_MIN="26.0"
IOS_MIN="26.0"
MACOS_MIN="14.0"

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output="$root/Artifacts"
work=""
verify_only=""

usage() { sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --output) output="$2"; shift 2 ;;
        --work-dir) work="$2"; shift 2 ;;
        --verify-only) verify_only="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "unknown argument: $1" >&2; usage ;;
    esac
done

# Without the assembly nothing fails: uavs3d falls back to C and decodes
# slower. Same failure shape as dav1d's, so the same kind of check.
verify_asm() {
    local framework="$1" failures=0
    echo "== verifying assembly is present =="
    while IFS= read -r binary; do
        local slice
        slice="$(basename "$(dirname "$(dirname "$binary")")")"
        for arch in $(lipo -archs "$binary"); do
            if [ "$arch" != "arm64" ]; then
                printf '   %-34s %-7s C only, by design\n' "$slice" "$arch"
                continue
            fi
            local symbols count
            symbols="$(nm -arch "$arch" "$binary" 2>/dev/null)"
            count="$(grep -c "_arm64$" <<< "$symbols" || true)"
            printf '   %-34s %-7s %s arm64 symbols\n' "$slice" "$arch" "$count"
            if [ "$count" -lt 100 ] || ! grep -q " T _uavs3d_funs_init_arm64$" <<< "$symbols"; then
                echo "   ERROR: $slice/$arch has no assembly - this is the C fallback path" >&2
                failures=$((failures + 1))
            fi
        done
    done < <(find "$framework" -name Libuavs3d -type f)
    [ "$failures" -eq 0 ] || { echo "verification failed" >&2; exit 1; }
    echo "   every arm64 slice carries assembly"
}

if [ -n "$verify_only" ]; then
    verify_asm "$verify_only"
    exit 0
fi

for tool in xcodebuild curl shasum; do
    command -v "$tool" >/dev/null || { echo "error: $tool is required" >&2; exit 1; }
done

if [ -z "$work" ]; then
    work="$(mktemp -d "${TMPDIR:-/tmp}/uavs3d-build.XXXXXX")"
    trap 'rm -rf "$work"' EXIT
fi
mkdir -p "$work"

archive="$work/uavs3d-$UAVS3D_COMMIT.tar.gz"
if [ ! -f "$archive" ] || [ "$(shasum -a 256 "$archive" | cut -d' ' -f1)" != "$UAVS3D_SHA256" ]; then
    echo "== downloading uavs3d $UAVS3D_COMMIT =="
    curl -fsSL -o "$archive" "$UAVS3D_URL"
fi
[ "$(shasum -a 256 "$archive" | cut -d' ' -f1)" = "$UAVS3D_SHA256" ] \
    || { echo "error: checksum mismatch for $archive" >&2; exit 1; }
src="$work/uavs3d-$UAVS3D_COMMIT"
rm -rf "$src"
tar -xzf "$archive" -C "$work"

# What version.sh would have written; uavs3d.c includes it from the root.
cat > "$src/version.h" <<VERSION
#ifndef __VERSION_H__
#define __VERSION_H__

#define VER_MAJOR  ${UAVS3D_VERSION%%.*}
#define VER_MINOR  $(cut -d. -f2 <<< "$UAVS3D_VERSION")
#define VER_BUILD  ${UAVS3D_VERSION##*.}

#define VERSION_TYPE "release"
#define VERSION_STR  "$UAVS3D_VERSION"
#define VERSION_SHA1 "$UAVS3D_COMMIT"

#endif // __VERSION_H__
VERSION

# source/CMakeLists.txt, transcribed. aux_source_directory takes every .c in
# a directory, not recursively.
common_sources=("$src"/source/decoder/*.c "$src"/source/decore/*.c)
arm64_sources=(
    arm64.c alf_arm64.S deblock_arm64.S def_arm64.S inter_pred_arm64.S
    intra_pred_arm64.S intra_pred_chroma_arm64.S itrans_arm64.c
    itrans_dct2_arm64.S itrans_dct8_dst7_arm64.S pixel_arm64.S sao_arm64.c
    sao_kernel_arm64.S
)

# group | sdk | arch | clang target triple | platform name for Info.plist
builds=(
    "tvos|appletvos|arm64|arm64-apple-tvos${TVOS_MIN}|AppleTVOS"
    "tvos-simulator|appletvsimulator|arm64|arm64-apple-tvos${TVOS_MIN}-simulator|AppleTVSimulator"
    "tvos-simulator|appletvsimulator|x86_64|x86_64-apple-tvos${TVOS_MIN}-simulator|AppleTVSimulator"
    "ios|iphoneos|arm64|arm64-apple-ios${IOS_MIN}|iPhoneOS"
    "ios-simulator|iphonesimulator|arm64|arm64-apple-ios${IOS_MIN}-simulator|iPhoneSimulator"
    "ios-simulator|iphonesimulator|x86_64|x86_64-apple-ios${IOS_MIN}-simulator|iPhoneSimulator"
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
    rm -rf "$build"
    mkdir -p "$build"

    # CMake's Release flags plus upstream's: C99, PIC, 10-bit. -target stamps
    # the platform load command, as in build-dav1d.sh.
    cflags=(-target "$triple" -isysroot "$sysroot" -std=c99 -fPIC -fno-common
            -O3 -DNDEBUG -DCOMPILE_10BIT=1 -I"$src/source/decore" -w)
    # sources as "path|extra flags"
    sources=()
    for file in "${common_sources[@]}"; do sources+=("$file|"); done
    case "$arch" in
        arm64)
            cflags+=(-D_arm64)
            for file in "${arm64_sources[@]}"; do
                sources+=("$src/source/decore/arm64/$file|")
            done
            ;;
        x86_64)
            for file in "$src"/source/decore/sse/*.c; do sources+=("$file|-msse4.2"); done
            for file in "$src"/source/decore/avx2/*.c; do sources+=("$file|-mavx2"); done
            ;;
        *) echo "unknown arch $arch" >&2; exit 1 ;;
    esac

    echo "== building $group $arch ($triple) =="
    objects=()
    for pair in "${sources[@]}"; do
        file="${pair%%|*}"
        extra="${pair#*|}"
        # Directory-qualified, because decore/ and decore/arm64/ share names.
        object="$build/$(basename "$(dirname "$file")")_$(basename "${file%.*}").o"
        # shellcheck disable=SC2086
        clang "${cflags[@]}" $extra -c "$file" -o "$object" \
            >> "$work/build-$group-$arch.log" 2>&1 \
            || { tail -40 "$work/build-$group-$arch.log" >&2; exit 1; }
        objects+=("$object")
    done
    libtool -static -no_warning_for_no_symbols -o "$build/libuavs3d.a" "${objects[@]}"

    if [ -z "${group_platform[$group]:-}" ]; then
        group_platform[$group]="$platform"
        group_order+=("$group")
    fi
    group_libs+=("$group|$build/libuavs3d.a")
done

frameworks=()
for group in "${group_order[@]}"; do
    platform="${group_platform[$group]}"
    libs=()
    for pair in "${group_libs[@]}"; do
        [ "${pair%%|*}" = "$group" ] && libs+=("${pair#*|}")
    done

    # The MPVKit artifact's framework and module name, so Package.swift's
    # target name stays put.
    fw="$work/frameworks/$group/Libuavs3d.framework"
    mkdir -p "$fw/Headers" "$fw/Modules"
    if [ "${#libs[@]}" -gt 1 ]; then
        lipo -create "${libs[@]}" -output "$fw/Libuavs3d"
    else
        cp "${libs[0]}" "$fw/Libuavs3d"
    fi
    cp "$src/source/decoder/uavs3d.h" "$fw/Headers/"
    cat > "$fw/Modules/module.modulemap" <<'MODULE'
framework module Libuavs3d [system] {
    umbrella "."
    export *
}
MODULE
    # MinimumOSVersion is deliberately out of reach of any real OS; see the
    # same block in build-dav1d.sh (ITMS-90208).
    cat > "$fw/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>Libuavs3d</string>
    <key>CFBundleIdentifier</key><string>ee.helop.Libuavs3d</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>Libuavs3d</string>
    <key>CFBundlePackageType</key><string>FMWK</string>
    <key>CFBundleShortVersionString</key><string>$UAVS3D_VERSION</string>
    <key>CFBundleSignature</key><string>????</string>
    <key>CFBundleSupportedPlatforms</key><array><string>$platform</string></array>
    <key>CFBundleVersion</key><string>$UAVS3D_VERSION</string>
    <key>MinimumOSVersion</key><string>100.0</string>
    <key>NSPrincipalClass</key><string></string>
</dict>
</plist>
PLIST
    frameworks+=(-framework "$fw")
done

echo "== assembling the xcframework =="
mkdir -p "$output"
rm -rf "$output/Libuavs3d.xcframework"
xcodebuild -create-xcframework "${frameworks[@]}" \
    -output "$output/Libuavs3d.xcframework" > /dev/null
cp "$src/COPYING" "$output/Libuavs3d.xcframework/COPYING"

verify_asm "$output/Libuavs3d.xcframework"
echo
echo "uavs3d $UAVS3D_VERSION ($UAVS3D_COMMIT) -> $output/Libuavs3d.xcframework"
du -sh "$output/Libuavs3d.xcframework"
