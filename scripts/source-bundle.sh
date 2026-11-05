#!/usr/bin/env bash
#
# Packs the complete corresponding source of an LGPL library a revision
# vendors, for attaching to that revision's GitHub release.
#
#   scripts/source-bundle.sh ffmpeg 1.0.5 /tmp/out
#   scripts/source-bundle.sh fribidi 1.1.0 /tmp/out --rev a1b2c
#
# The LGPL asks that whoever distributes the object code offers its source
# from the same place, and FFmpeg's compliance checklist asks for a tarball
# with the changes and the configure line beside it. A URL and a checksum in
# the repository are not that, so every release carries these archives:
#
#   ffmpeg-<version>.tar.gz   upstream's release tarball, unmodified
#   changes.diff              every patch applied before configure
#   build/                    the revision's build script, codec selection,
#                             BUILD.json records (the configure line for every
#                             platform and architecture) and provenance README
#   COPYING.LGPLv2.1          the licence
#   README.txt                how the pieces fit together
#
#   fribidi-<version>.tar.xz  upstream's release tarball, unmodified
#   build/                    the revision's build script and provenance README
#   COPYING                   the licence
#   README.txt                how the pieces fit together
#
# FriBidi is linked statically inside Libass.xcframework. libass (ISC),
# FreeType (FTL) and HarfBuzz (MIT) in the same framework are permissive; their
# licences travel in the framework's LICENSES folder.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
usage="usage: $(basename "$0") ffmpeg|fribidi <label> <output-dir> [--rev <revision>]"
kind="${1:?$usage}"
label="${2:?$usage}"
out="${3:?$usage}"
shift 3
rev="$label"
while [ $# -gt 0 ]; do
    case "$1" in
        --rev) rev="${2:?--rev needs a revision}"; shift ;;
        *) echo "error: unknown option $1" >&2; exit 2 ;;
    esac
    shift
done

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
git -C "$root" rev-parse --verify --quiet "${rev}^{commit}" >/dev/null || die "unknown revision ${rev}"

constant() {
    git -C "$root" show "${rev}:${script}" | sed -n "s/^$1 *= *\"\(.*\)\"$/\1/p" | head -1
}

case "$kind" in
    ffmpeg)
        # Before 1.0.2 only libavformat was built here, by a different script.
        script=""
        for candidate in scripts/build-ffmpeg.py scripts/build-ffmpeg-format.py; do
            git -C "$root" cat-file -e "${rev}:${candidate}" 2>/dev/null && { script="$candidate"; break; }
        done
        [ -n "$script" ] || die "${rev} builds no FFmpeg library here"
        display="FFmpeg"
        version="$(constant VERSION)"
        url="$(constant SOURCE_URL)"
        sha="$(constant SOURCE_SHA)"
        upstream="ffmpeg-${version}.tar.gz"
        ;;
    fribidi)
        script="scripts/build-libass.sh"
        git -C "$root" cat-file -e "${rev}:${script}" 2>/dev/null || die "${rev} builds no FriBidi here"
        display="FriBidi"
        version="$(constant FRIBIDI_VERSION)"
        sha="$(constant FRIBIDI_SHA256)"
        url="https://github.com/fribidi/fribidi/releases/download/v${version}/fribidi-${version}.tar.xz"
        upstream="fribidi-${version}.tar.xz"
        ;;
    *) die "$usage" ;;
esac
[ -n "$version" ] && [ -n "$url" ] && [ -n "$sha" ] || die "could not read the ${display} pin from ${script}"

sha256() { sha256sum "$1" | cut -d' ' -f1; }
cache="${TMPDIR:-/tmp}/lagoon-${kind}-source-cache"
tarball="$cache/$upstream"
mkdir -p "$cache"
if [ ! -f "$tarball" ] || [ "$(sha256 "$tarball")" != "$sha" ]; then
    curl -fsSL --proto =https --proto-redir =https "$url" -o "$tarball.partial"
    mv "$tarball.partial" "$tarball"
fi
[ "$(sha256 "$tarball")" = "$sha" ] || die "downloaded source does not match ${sha}"

name="lagoon-engine-${label}-${kind}-${version}-source"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
stage="$work/$name"
mkdir -p "$stage/build"
cp "$tarball" "$stage/$upstream"

commit="$(git -C "$root" rev-parse "${rev}^{commit}")"
cat > "$stage/README.txt" <<EOF
${display} ${version}, as built into LagoonEngine ${label}
Engine revision: ${commit}
Repository: https://github.com/helop-ou/lagoon-engine

EOF

if [ "$kind" = ffmpeg ]; then
    paths=("$script")
    while IFS= read -r path; do
        paths+=("$path")
    done < <(git -C "$root" ls-tree -r --name-only "$rev" -- Patches scripts/ffmpeg-selections.txt Artifacts \
        | grep -E '^Patches/.*\.patch$|^scripts/ffmpeg-selections\.txt$|^Artifacts/(FFmpeg|Libavformat)\.README\.md$|^Artifacts/Lib[a-z]+\.xcframework/(BUILD\.json|COPYING\.LGPLv2\.1|LICENSE\.md)$')
    git -C "$root" archive "$rev" -- "${paths[@]}" | tar -x -C "$stage/build"

    : > "$stage/changes.diff"
    for patch in "$stage"/build/Patches/*.patch; do
        [ -f "$patch" ] && cat "$patch" >> "$stage/changes.diff"
    done

    licence="$(find "$stage/build/Artifacts" -name COPYING.LGPLv2.1 | head -1)"
    if [ -n "$licence" ]; then
        cp "$licence" "$stage/COPYING.LGPLv2.1"
    else
        tar -xzf "$tarball" -C "$work" --strip-components=1 "FFmpeg-n${version}/COPYING.LGPLv2.1"
        mv "$work/COPYING.LGPLv2.1" "$stage/COPYING.LGPLv2.1"
    fi

    cat >> "$stage/README.txt" <<EOF
LagoonEngine vendors static FFmpeg libraries under the GNU Lesser General
Public License, version 2.1 or later (COPYING.LGPLv2.1). This archive is their
complete corresponding source.

- ffmpeg-${version}.tar.gz is upstream's release tarball, unmodified.
  Source: ${url}
  SHA-256: ${sha}
- changes.diff holds every change made to it. Apply it with
  "patch -p1 < changes.diff" in the extracted source.
- build/${script} is the script that configured and built the libraries. It
  downloads the same tarball and applies the same patches. The configure line
  for every platform and architecture is recorded in the BUILD.json files
  under build/Artifacts, and the provenance README beside them explains the
  choices.

The build enables no GPL, nonfree or version 3 components.
EOF
else
    git -C "$root" archive "$rev" -- "$script" Artifacts/Libass.README.md | tar -x -C "$stage/build"
    tar -xJf "$tarball" -C "$work" "fribidi-${version}/COPYING"
    mv "$work/fribidi-${version}/COPYING" "$stage/COPYING"

    cat >> "$stage/README.txt" <<EOF
LagoonEngine links FriBidi statically, inside Libass.xcframework, under the
GNU Lesser General Public License, version 2.1 or later (COPYING). This
archive is its complete corresponding source.

- fribidi-${version}.tar.xz is upstream's release tarball, unmodified.
  Source: ${url}
  SHA-256: ${sha}
- No changes are made to it.
- build/${script} is the script that configured and built it, with libass,
  FreeType and HarfBuzz; build/Artifacts/Libass.README.md explains the
  choices.
EOF
fi

mkdir -p "$out"
tar -czf "$out/${name}.tar.gz" -C "$work" "$name"
echo "$out/${name}.tar.gz"
