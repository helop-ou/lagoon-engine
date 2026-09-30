#!/usr/bin/env bash
#
# Builds libass and the three libraries it renders with (FreeType, FriBidi,
# HarfBuzz) as one static xcframework for the engine's styled ASS/SSA
# subtitles. Sources: each project's own release tarball, SHA-256 checked.
#
#   scripts/build-libass.sh                     # build and install into the package
#   scripts/build-libass.sh --output /tmp/out   # build somewhere else
#   scripts/build-libass.sh --verify-only <xcframework>
#
# Requires meson, ninja, pkg-config and nasm (brew install meson ninja
# pkg-config nasm); nasm assembles libass's x86 routines for the simulators.
#
# FreeType reads fonts through stdio rather than mmap, and HarfBuzz is built
# with HB_NO_MMAP, so neither imports fstat (a privacy-manifest API). HarfBuzz
# then leaves its macOS resource-fork reader unused, which its own pragmas make
# an error (HB_NO_PRAGMA_GCC_DIAGNOSTIC_ERROR turns those off); the function is
# not emitted, and the verification checks that.
#
# Licences: libass ISC, FreeType FTL (chosen over its GPL-2.0 alternative),
# HarfBuzz MIT, FriBidi LGPL-2.1-or-later. FriBidi's source travels with each
# release in the source bundle, as FFmpeg's does. Fonts come from CoreText and
# from the attachments in the media; fontconfig is not built.
#
set -euo pipefail

LIBASS_VERSION="0.17.5"
LIBASS_URL="https://github.com/libass/libass/releases/download/${LIBASS_VERSION}/libass-${LIBASS_VERSION}.tar.xz"
LIBASS_SHA256="2dca25c0e0c837ddf00b52011b3f82cac1e4ddd3ad018227806b0c2288864acc"
FREETYPE_VERSION="2.14.3"
FREETYPE_URL="https://download.savannah.gnu.org/releases/freetype/freetype-${FREETYPE_VERSION}.tar.xz"
FREETYPE_SHA256="36bc4f1cc413335368ee656c42afca65c5a3987e8768cc28cf11ba775e785a5f"
FRIBIDI_VERSION="1.0.17"
FRIBIDI_URL="https://github.com/fribidi/fribidi/releases/download/v${FRIBIDI_VERSION}/fribidi-${FRIBIDI_VERSION}.tar.xz"
FRIBIDI_SHA256="6949dcde27d41cebad1fd741fcafc36d55a1020d2d872d4a6eb3914caabbada2"
HARFBUZZ_VERSION="14.5.0"
HARFBUZZ_URL="https://github.com/harfbuzz/harfbuzz/releases/download/${HARFBUZZ_VERSION}/harfbuzz-${HARFBUZZ_VERSION}.tar.xz"
HARFBUZZ_SHA256="b7132e148358a45185c9feafd049dbaf243649d3c44414b3534d9c95d18592b9"
# Matches the engine's deployment targets; the artifact cannot be used below
# them.
TVOS_MIN="26.0"
IOS_MIN="26.0"
MACOS_MIN="14.0"

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output="$root/Artifacts"
work=""
verify_only=""

usage() { sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --output) output="$2"; shift 2 ;;
        --work-dir) work="$2"; shift 2 ;;
        --verify-only) verify_only="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "unknown argument: $1" >&2; usage ;;
    esac
done

# Every slice must carry all four libraries, no fontconfig, and no file
# metadata call: a missing library links only to fail at the first styled cue,
# fontconfig would look for a configuration file tvOS does not have, and stat
# and its relatives are privacy-manifest APIs Lagoon would have to declare.
verify_contents() {
    local framework="$1" failures=0
    echo "== verifying the four libraries are linked =="
    while IFS= read -r binary; do
        local slice
        slice="$(basename "$(dirname "$(dirname "$binary")")")"
        for arch in $(lipo -archs "$binary"); do
            local symbols
            symbols="$(nm -arch "$arch" "$binary" 2>/dev/null)"
            for required in _ass_library_init _ass_render_frame _FT_Init_FreeType \
                _fribidi_get_par_embedding_levels_ex _hb_shape _hb_ft_font_create; do
                if ! grep -q " T $required$" <<< "$symbols"; then
                    echo "   ERROR: $slice/$arch does not define ${required#_}" >&2
                    failures=$((failures + 1))
                fi
            done
            if grep -q " U _Fc" <<< "$symbols"; then
                echo "   ERROR: $slice/$arch references fontconfig" >&2
                failures=$((failures + 1))
            fi
            # x86_64 macOS spells the 64-bit-inode variants with a suffix,
            # as in _fstat$INODE64.
            if grep -Eq ' U _(f|l)?stat(at)?(64)?(\$INODE64)?$| U _getattrlist(bulk)?$| U _fgetattrlist$' <<< "$symbols"; then
                echo "   ERROR: $slice/$arch imports a file metadata API" >&2
                failures=$((failures + 1))
            fi
            printf '   %-34s %-7s libass+FreeType+FriBidi+HarfBuzz\n' "$slice" "$arch"
        done
    done < <(find "$framework" -name Libass -type f)
    [ "$failures" -eq 0 ] || { echo "verification failed" >&2; exit 1; }
}

if [ -n "$verify_only" ]; then
    verify_contents "$verify_only"
    exit 0
fi

for tool in meson ninja pkg-config nasm xcodebuild curl shasum libtool; do
    command -v "$tool" >/dev/null || { echo "error: $tool is required" >&2; exit 1; }
done

if [ -z "$work" ]; then
    work="$(mktemp -d "${TMPDIR:-/tmp}/libass-build.XXXXXX")"
    trap 'rm -rf "$work"' EXIT
fi
mkdir -p "$work"

# name | version | url | sha256
fetch() {
    local name="$1" version="$2" url="$3" sha="$4"
    local archive="$work/$name-$version.tar.xz"
    if [ ! -f "$archive" ] || [ "$(shasum -a 256 "$archive" | cut -d' ' -f1)" != "$sha" ]; then
        echo "== downloading $name $version =="
        curl -fsSL -o "$archive" "$url"
    fi
    [ "$(shasum -a 256 "$archive" | cut -d' ' -f1)" = "$sha" ] \
        || { echo "error: checksum mismatch for $archive" >&2; exit 1; }
    rm -rf "$work/$name-$version"
    tar -xf "$archive" -C "$work"
}
fetch freetype "$FREETYPE_VERSION" "$FREETYPE_URL" "$FREETYPE_SHA256"
fetch fribidi "$FRIBIDI_VERSION" "$FRIBIDI_URL" "$FRIBIDI_SHA256"
fetch harfbuzz "$HARFBUZZ_VERSION" "$HARFBUZZ_URL" "$HARFBUZZ_SHA256"
fetch libass "$LIBASS_VERSION" "$LIBASS_URL" "$LIBASS_SHA256"

# group | sdk | arch | clang target triple | platform name for Info.plist
#
# The same slices as lcms2 and dav1d: fat simulators because a generic
# simulator build compiles both, and macOS only because SwiftPM resolves the
# package for the host when Xcode indexes it.
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
headers=""

# name | source dir | meson options
meson_build() {
    local name="$1" src="$2"
    shift 2
    local build="$work/build-$name-$group-$arch"
    rm -rf "$build"
    meson setup "$build" "$src" \
        --cross-file "$cross" \
        --prefix "$prefix" \
        --libdir lib \
        --buildtype release \
        --default-library static \
        "$@" \
        > "$work/setup-$name-$group-$arch.log" 2>&1 \
        || { tail -40 "$work/setup-$name-$group-$arch.log" >&2; exit 1; }
    ninja -C "$build" > "$work/ninja-$name-$group-$arch.log" 2>&1 \
        || { tail -40 "$work/ninja-$name-$group-$arch.log" >&2; exit 1; }
    ninja -C "$build" install > /dev/null 2>&1
}

for entry in "${builds[@]}"; do
    IFS='|' read -r group sdk arch triple platform <<< "$entry"
    sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
    prefix="$work/install-$group-$arch"
    rm -rf "$prefix"
    mkdir -p "$prefix/lib/pkgconfig"

    case "$arch" in
        arm64) cpu_family="aarch64" ;;
        x86_64) cpu_family="x86_64" ;;
        *) echo "unknown arch $arch" >&2; exit 1 ;;
    esac

    # Only this slice's own prefix is searched, so nothing from Homebrew
    # leaks into a device build.
    cross="$work/cross-$group-$arch.ini"
    cat > "$cross" <<CROSS
[binaries]
c = ['clang', '-target', '$triple', '-isysroot', '$sysroot']
cpp = ['clang++', '-target', '$triple', '-isysroot', '$sysroot']
objc = ['clang', '-target', '$triple', '-isysroot', '$sysroot']
nasm = '$(command -v nasm)'
ar = '$(xcrun --sdk "$sdk" --find ar)'
strip = '$(xcrun --sdk "$sdk" --find strip)'
pkg-config = '$(command -v pkg-config)'

[properties]
pkg_config_libdir = ['$prefix/lib/pkgconfig']

[built-in options]
c_args = ['-target', '$triple', '-isysroot', '$sysroot', '-fno-common']
cpp_args = ['-target', '$triple', '-isysroot', '$sysroot', '-fno-common', '-DHB_NO_MMAP', '-DHB_NO_PRAGMA_GCC_DIAGNOSTIC_ERROR', '-Wno-error=unused-function']
c_link_args = ['-target', '$triple', '-isysroot', '$sysroot']
cpp_link_args = ['-target', '$triple', '-isysroot', '$sysroot']

[host_machine]
system = 'darwin'
subsystem = '${sdk}'
kernel = 'xnu'
cpu_family = '$cpu_family'
cpu = '$cpu_family'
endian = 'little'
CROSS

    echo "== building $group $arch ($triple) =="
    meson_build freetype "$work/freetype-$FREETYPE_VERSION" \
        -Dbrotli=disabled -Dharfbuzz=disabled -Dpng=disabled -Dmmap=disabled \
        -Dzlib=internal -Dtests=disabled
    meson_build fribidi "$work/fribidi-$FRIBIDI_VERSION" \
        -Ddocs=false -Dbin=false -Dtests=false
    meson_build harfbuzz "$work/harfbuzz-$HARFBUZZ_VERSION" \
        -Dfreetype=enabled -Dglib=disabled -Dgobject=disabled -Dcairo=disabled \
        -Dchafa=disabled -Dpng=disabled -Dzlib=disabled -Dicu=disabled \
        -Dgraphite=disabled -Dfontations=disabled -Dcoretext=disabled \
        -Dharfrust=disabled -Dkbts=disabled -Dwasm=disabled -Draster=disabled \
        -Dvector=disabled -Dgpu=disabled -Dsubset=disabled -Dtests=disabled \
        -Dintrospection=disabled -Ddocs=disabled -Dutilities=disabled \
        -Dbenchmark=disabled
    meson_build libass "$work/libass-$LIBASS_VERSION" \
        -Dfontconfig=disabled -Dcoretext=enabled -Ddirectwrite=disabled \
        -Dasm=enabled -Dlibunibreak=disabled -Drequire-system-font-provider=true \
        -Dtest=disabled -Dcompare=disabled -Dprofile=disabled -Dfuzz=disabled \
        -Dcheckasm=disabled

    # One archive per slice, so the package links a single binary target.
    merged="$work/merged-$group-$arch.a"
    libtool -static -o "$merged" \
        "$prefix/lib/libass.a" "$prefix/lib/libfreetype.a" \
        "$prefix/lib/libfribidi.a" "$prefix/lib/libharfbuzz.a" 2> /dev/null
    # Local symbols only; the exported API is untouched. Roughly halves each
    # slice, as for libdovi.
    strip -x -S "$merged" 2> /dev/null
    headers="$prefix/include/ass"

    if [ -z "${group_platform[$group]:-}" ]; then
        group_platform[$group]="$platform"
        group_order+=("$group")
    fi
    group_libs+=("$group|$merged")
done

frameworks=()
for group in "${group_order[@]}"; do
    platform="${group_platform[$group]}"
    libs=()
    for pair in "${group_libs[@]}"; do
        [ "${pair%%|*}" = "$group" ] && libs+=("${pair#*|}")
    done

    fw="$work/frameworks/$group/Libass.framework"
    mkdir -p "$fw/Headers/ass" "$fw/Modules"
    if [ "${#libs[@]}" -gt 1 ]; then
        lipo -create "${libs[@]}" -output "$fw/Libass"
    else
        cp "${libs[0]}" "$fw/Libass"
    fi
    # Only libass's API is exposed; the engine never calls the others.
    cp "$headers/ass.h" "$headers/ass_types.h" "$fw/Headers/ass/"
    cat > "$fw/Headers/Libass.h" <<'UMBRELLA'
#include "ass/ass.h"
UMBRELLA
    cat > "$fw/Modules/module.modulemap" <<'MODULE'
framework module Libass [system] {
    umbrella header "Libass.h"
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
    <key>CFBundleExecutable</key><string>Libass</string>
    <key>CFBundleIdentifier</key><string>ee.helop.libass</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>Libass</string>
    <key>CFBundlePackageType</key><string>FMWK</string>
    <key>CFBundleShortVersionString</key><string>$LIBASS_VERSION</string>
    <key>CFBundleSignature</key><string>????</string>
    <key>CFBundleSupportedPlatforms</key><array><string>$platform</string></array>
    <key>CFBundleVersion</key><string>$LIBASS_VERSION</string>
    <key>MinimumOSVersion</key><string>100.0</string>
    <key>NSPrincipalClass</key><string></string>
</dict>
</plist>
PLIST
    frameworks+=(-framework "$fw")
done

echo "== assembling the xcframework =="
mkdir -p "$output"
rm -rf "$output/Libass.xcframework"
xcodebuild -create-xcframework "${frameworks[@]}" \
    -output "$output/Libass.xcframework" > /dev/null
licences="$output/Libass.xcframework/LICENSES"
mkdir -p "$licences"
cp "$work/libass-$LIBASS_VERSION/COPYING" "$licences/libass.COPYING"
cp "$work/freetype-$FREETYPE_VERSION/LICENSE.TXT" "$licences/freetype.LICENSE.TXT"
cp "$work/freetype-$FREETYPE_VERSION/docs/FTL.TXT" "$licences/freetype.FTL.TXT"
cp "$work/fribidi-$FRIBIDI_VERSION/COPYING" "$licences/fribidi.COPYING"
cp "$work/harfbuzz-$HARFBUZZ_VERSION/COPYING" "$licences/harfbuzz.COPYING"

verify_contents "$output/Libass.xcframework"
echo
echo "libass $LIBASS_VERSION, FreeType $FREETYPE_VERSION, FriBidi $FRIBIDI_VERSION," \
    "HarfBuzz $HARFBUZZ_VERSION -> $output/Libass.xcframework"
du -sh "$output/Libass.xcframework"
