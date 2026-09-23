#!/usr/bin/env bash
#
# Packs the complete corresponding source of the FFmpeg libraries a revision
# vendors, for attaching to that revision's GitHub release.
#
#   scripts/ffmpeg-source-bundle.sh 1.0.5 /tmp/out
#   scripts/ffmpeg-source-bundle.sh 1.0.5 /tmp/out --rev a1b2c
#
# The LGPL asks that whoever distributes FFmpeg object code offers its source
# from the same place, and FFmpeg's compliance checklist asks for a tarball
# with the changes and the configure line beside it. A URL and a checksum in
# the repository are not that, so every release carries this archive:
#
#   ffmpeg-<version>.tar.gz   upstream's release tarball, unmodified
#   changes.diff              every patch applied before configure
#   build/                    the revision's build script, codec selection,
#                             BUILD.json records (the configure line for every
#                             platform and architecture) and provenance README
#   COPYING.LGPLv2.1          the licence
#   README.txt                how the pieces fit together
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
label="${1:?usage: $(basename "$0") <label> <output-dir> [--rev <revision>]}"
out="${2:?usage: $(basename "$0") <label> <output-dir> [--rev <revision>]}"
shift 2
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

# Before 1.0.2 only libavformat was built here, by a different script.
script=""
for candidate in scripts/build-ffmpeg.py scripts/build-ffmpeg-format.py; do
    git -C "$root" cat-file -e "${rev}:${candidate}" 2>/dev/null && { script="$candidate"; break; }
done
[ -n "$script" ] || die "${rev} builds no FFmpeg library here"

constant() {
    git -C "$root" show "${rev}:${script}" | sed -n "s/^$1 = \"\(.*\)\"$/\1/p" | head -1
}
version="$(constant VERSION)"
url="$(constant SOURCE_URL)"
sha="$(constant SOURCE_SHA)"
[ -n "$version" ] && [ -n "$url" ] && [ -n "$sha" ] || die "could not read the source pin from ${script}"

cache="${TMPDIR:-/tmp}/lagoon-ffmpeg-source-cache"
tarball="$cache/ffmpeg-${version}.tar.gz"
mkdir -p "$cache"
if [ ! -f "$tarball" ] || [ "$(shasum -a 256 "$tarball" | cut -d' ' -f1)" != "$sha" ]; then
    curl -fsSL "$url" -o "$tarball.partial"
    mv "$tarball.partial" "$tarball"
fi
[ "$(shasum -a 256 "$tarball" | cut -d' ' -f1)" = "$sha" ] || die "downloaded source does not match ${sha}"

name="lagoon-engine-${label}-ffmpeg-${version}-source"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
stage="$work/$name"
mkdir -p "$stage/build"

cp "$tarball" "$stage/ffmpeg-${version}.tar.gz"

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

commit="$(git -C "$root" rev-parse "${rev}^{commit}")"
cat > "$stage/README.txt" <<EOF
FFmpeg ${version}, as built into LagoonEngine ${label}
Engine revision: ${commit}
Repository: https://github.com/helop-ou/lagoon-engine

LagoonEngine vendors static FFmpeg libraries under the GNU Lesser General
Public License, version 2.1 or later (COPYING.LGPLv2.1). This archive is their
complete corresponding source.

- ffmpeg-${version}.tar.gz is upstream's release tarball, unmodified.
  Source: ${url}
  SHA-256: ${sha}
- changes.diff holds every change made to it. Apply it with
  "patch -p1 < changes.diff" in the extracted source.
- build/${script} is the script that configured and built the libraries. It
  downloads the same tarball and applies the same patch. The configure line
  for every platform and architecture is recorded in the BUILD.json files
  under build/Artifacts, and the provenance README beside them explains the
  choices.

The build enables no GPL, nonfree or version 3 components.
EOF

mkdir -p "$out"
tar -czf "$out/${name}.tar.gz" -C "$work" "$name"
echo "$out/${name}.tar.gz"
