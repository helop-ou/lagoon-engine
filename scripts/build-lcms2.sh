#!/usr/bin/env bash
#
# Builds Little CMS 2 (lcms2) as an xcframework for the engine.
#
# libavcodec is configured with --enable-lcms2, so this is linked whether or
# not a host ever asks FFmpeg to apply an ICC profile. It used to come from
# mpvkit/lcms2-build 2.17.0, fetched at resolve time from a repository nobody
# here controls. Building it here removes that download; the source is the
# release tarball from Little CMS's own repository, SHA-256 checked.
#
#   scripts/build-lcms2.sh                     # build and install into the package
#   scripts/build-lcms2.sh --output /tmp/out   # build somewhere else
#   scripts/build-lcms2.sh --verify-only <xcframework>
#
# Requires meson and ninja (brew install meson ninja).
#
# lcms2 itself is MIT. Its source tree also carries two optional plugins,
# fast_float and threaded, which are GPL-3.0; meson builds neither unless
# asked, and the verification below fails the build if either one's entry
# point ever turns up in the library.
#
set -euo pipefail

LCMS2_VERSION="2.17"
LCMS2_URL="https://github.com/mm2/Little-CMS/releases/download/lcms${LCMS2_VERSION}/lcms2-${LCMS2_VERSION}.tar.gz"
LCMS2_SHA256="d11af569e42a1baa1650d20ad61d12e41af4fead4aa7964a01f93b08b53ab074"
# Matches the engine's deployment targets; the artifact cannot be used below
# these.
TVOS_MIN="26.0"
IOS_MIN="26.0"
MACOS_MIN="14.0"

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output="$root/Artifacts"
work=""
verify_only=""

usage() { sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --output) output="$2"; shift 2 ;;
        --work-dir) work="$2"; shift 2 ;;
        --verify-only) verify_only="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "unknown argument: $1" >&2; usage ;;
    esac
done

# The two GPL-3.0 plugins register themselves through these entry points. A
# library carrying either is no longer MIT, and nothing else would notice.
verify_license() {
    local framework="$1" failures=0
    echo "== verifying no GPL plugin is linked =="
    while IFS= read -r binary; do
        local slice
        slice="$(basename "$(dirname "$(dirname "$binary")")")"
        for arch in $(lipo -archs "$binary"); do
            local symbols
            symbols="$(nm -arch "$arch" "$binary" 2>/dev/null)"
            if grep -q "_cmsFastFloatExtensions\|_cmsThreadedExtensions" <<< "$symbols"; then
                echo "   ERROR: $slice/$arch links a GPL-3.0 plugin" >&2
                failures=$((failures + 1))
            fi
            if ! grep -q " T _cmsCreateTransform$" <<< "$symbols"; then
                echo "   ERROR: $slice/$arch does not define cmsCreateTransform" >&2
                failures=$((failures + 1))
            fi
            printf '   %-34s %-7s MIT only\n' "$slice" "$arch"
        done
    done < <(find "$framework" -name lcms2 -type f)
    [ "$failures" -eq 0 ] || { echo "verification failed" >&2; exit 1; }
}

if [ -n "$verify_only" ]; then
    verify_license "$verify_only"
    exit 0
fi

for tool in meson ninja xcodebuild curl shasum; do
    command -v "$tool" >/dev/null || { echo "error: $tool is required" >&2; exit 1; }
done

if [ -z "$work" ]; then
    work="$(mktemp -d "${TMPDIR:-/tmp}/lcms2-build.XXXXXX")"
    trap 'rm -rf "$work"' EXIT
fi
mkdir -p "$work"

archive="$work/lcms2-$LCMS2_VERSION.tar.gz"
if [ ! -f "$archive" ] || [ "$(shasum -a 256 "$archive" | cut -d' ' -f1)" != "$LCMS2_SHA256" ]; then
    echo "== downloading lcms2 $LCMS2_VERSION =="
    curl -fsSL -o "$archive" "$LCMS2_URL"
fi
[ "$(shasum -a 256 "$archive" | cut -d' ' -f1)" = "$LCMS2_SHA256" ] \
    || { echo "error: checksum mismatch for $archive" >&2; exit 1; }
src="$work/lcms2-$LCMS2_VERSION"
rm -rf "$src"
tar -xzf "$archive" -C "$work"

# group | sdk | arch | clang target triple | platform name for Info.plist
#
# One build per architecture; architectures sharing a group are lipo'd into one
# fat framework, which is what an xcframework slice is. Same slices as dav1d:
# the simulators and macOS are fat because a generic simulator build compiles
# both, and macOS exists only because SwiftPM resolves the package for the host
# when Xcode indexes it.
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
    prefix="$work/install-$group-$arch"
    rm -rf "$build" "$prefix"

    case "$arch" in
        arm64) cpu_family="aarch64" ;;
        x86_64) cpu_family="x86_64" ;;
        *) echo "unknown arch $arch" >&2; exit 1 ;;
    esac

    cat > "$work/cross-$group-$arch.ini" <<CROSS
[binaries]
c = ['clang', '-target', '$triple', '-isysroot', '$sysroot']
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
cpu = '$cpu_family'
endian = 'little'
CROSS

    echo "== building $group $arch ($triple) =="
    meson setup "$build" "$src" \
        --cross-file "$work/cross-$group-$arch.ini" \
        --prefix "$prefix" \
        --buildtype release \
        --default-library static \
        -Dtests=disabled \
        -Djpeg=disabled \
        -Dtiff=disabled \
        -Dutils=false \
        -Dfastfloat=false \
        -Dthreaded=false \
        > "$work/setup-$group-$arch.log" 2>&1 \
        || { tail -40 "$work/setup-$group-$arch.log" >&2; exit 1; }

    ninja -C "$build" > "$work/ninja-$group-$arch.log" 2>&1 \
        || { tail -40 "$work/ninja-$group-$arch.log" >&2; exit 1; }
    ninja -C "$build" install > /dev/null 2>&1

    if [ -z "${group_platform[$group]:-}" ]; then
        group_platform[$group]="$platform"
        group_order+=("$group")
    fi
    group_libs+=("$group|$prefix/lib/liblcms2.a")
done

frameworks=()
for group in "${group_order[@]}"; do
    platform="${group_platform[$group]}"
    libs=()
    for pair in "${group_libs[@]}"; do
        [ "${pair%%|*}" = "$group" ] && libs+=("${pair#*|}")
    done

    # Same framework and module name the MPVKit artifact used, so the
    # Package.swift target name and anything built against it do not move.
    fw="$work/frameworks/$group/lcms2.framework"
    mkdir -p "$fw/Headers" "$fw/Modules"
    if [ "${#libs[@]}" -gt 1 ]; then
        lipo -create "${libs[@]}" -output "$fw/lcms2"
    else
        cp "${libs[0]}" "$fw/lcms2"
    fi
    cp "$src/include/lcms2.h" "$src/include/lcms2_plugin.h" "$fw/Headers/"
    cat > "$fw/Modules/module.modulemap" <<'MODULE'
framework module lcms2 [system] {
    umbrella "."
    export *
}
MODULE
    # MinimumOSVersion is deliberately out of reach of any real OS; see the
    # same block in build-dav1d.sh for why (ITMS-90208, build 74).
    cat > "$fw/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>lcms2</string>
    <key>CFBundleIdentifier</key><string>ee.helop.lcms2</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>lcms2</string>
    <key>CFBundlePackageType</key><string>FMWK</string>
    <key>CFBundleShortVersionString</key><string>$LCMS2_VERSION</string>
    <key>CFBundleSignature</key><string>????</string>
    <key>CFBundleSupportedPlatforms</key><array><string>$platform</string></array>
    <key>CFBundleVersion</key><string>$LCMS2_VERSION</string>
    <key>MinimumOSVersion</key><string>100.0</string>
    <key>NSPrincipalClass</key><string></string>
</dict>
</plist>
PLIST
    frameworks+=(-framework "$fw")
done

echo "== assembling the xcframework =="
mkdir -p "$output"
rm -rf "$output/lcms2.xcframework"
xcodebuild -create-xcframework "${frameworks[@]}" \
    -output "$output/lcms2.xcframework" > /dev/null
cp "$src/LICENSE" "$output/lcms2.xcframework/LICENSE"

verify_license "$output/lcms2.xcframework"
echo
echo "lcms2 $LCMS2_VERSION -> $output/lcms2.xcframework"
du -sh "$output/lcms2.xcframework"
