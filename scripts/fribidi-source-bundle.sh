#!/usr/bin/env bash
#
# Packs the complete corresponding source of the FriBidi library a revision
# vendors inside Libass.xcframework, for attaching to that revision's GitHub
# release.
#
#   scripts/fribidi-source-bundle.sh 1.1.0 /tmp/out
#   scripts/fribidi-source-bundle.sh 1.1.0 /tmp/out --rev a1b2c
#
# FriBidi is LGPL-2.1-or-later and linked statically, so, as with FFmpeg, its
# source is offered from the same place as the binaries:
#
#   fribidi-<version>.tar.xz  upstream's release tarball, unmodified
#   build/                    the revision's build script and provenance README
#   COPYING                   the licence
#   README.txt                how the pieces fit together
#
# libass (ISC), FreeType (FTL) and HarfBuzz (MIT) in the same framework are
# permissive; their licences travel in the framework's LICENSES folder.
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
script="scripts/build-libass.sh"
git -C "$root" cat-file -e "${rev}:${script}" 2>/dev/null || die "${rev} builds no FriBidi here"

constant() {
    git -C "$root" show "${rev}:${script}" | sed -n "s/^$1=\"\(.*\)\"$/\1/p" | head -1
}
version="$(constant FRIBIDI_VERSION)"
sha="$(constant FRIBIDI_SHA256)"
url="https://github.com/fribidi/fribidi/releases/download/v${version}/fribidi-${version}.tar.xz"
[ -n "$version" ] && [ -n "$sha" ] || die "could not read the FriBidi pin from ${script}"

cache="${TMPDIR:-/tmp}/lagoon-fribidi-source-cache"
tarball="$cache/fribidi-${version}.tar.xz"
mkdir -p "$cache"
if [ ! -f "$tarball" ] || [ "$(shasum -a 256 "$tarball" | cut -d' ' -f1)" != "$sha" ]; then
    curl -fsSL "$url" -o "$tarball.partial"
    mv "$tarball.partial" "$tarball"
fi
[ "$(shasum -a 256 "$tarball" | cut -d' ' -f1)" = "$sha" ] || die "downloaded source does not match ${sha}"

name="lagoon-engine-${label}-fribidi-${version}-source"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
stage="$work/$name"
mkdir -p "$stage/build"

cp "$tarball" "$stage/fribidi-${version}.tar.xz"
git -C "$root" archive "$rev" -- "$script" Artifacts/Libass.README.md | tar -x -C "$stage/build"
tar -xJf "$tarball" -C "$work" "fribidi-${version}/COPYING"
mv "$work/fribidi-${version}/COPYING" "$stage/COPYING"

commit="$(git -C "$root" rev-parse "${rev}^{commit}")"
cat > "$stage/README.txt" <<EOF
FriBidi ${version}, as built into LagoonEngine ${label}
Engine revision: ${commit}
Repository: https://github.com/helop-ou/lagoon-engine

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

mkdir -p "$out"
tar -czf "$out/${name}.tar.gz" -C "$work" "$name"
echo "$out/${name}.tar.gz"
