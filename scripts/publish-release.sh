#!/usr/bin/env bash
#
# Tags a version of the package and creates its GitHub release.
#
#   scripts/publish-release.sh 1.1.0             # tags and releases
#   scripts/publish-release.sh 1.1.0 --dry-run   # print what it would do
#   scripts/publish-release.sh 1.1.0 --rev a1b2c
#
# Everything before the release is a guard. Dependents resolve a tag without
# asking, and a published tag cannot be taken back cleanly.
#
# --no-verify skips the build and test gate. Only for re-releasing a revision
# already proven green.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version_file="$root/Sources/LagoonEngine/EngineVersion.swift"
changelog="$root/CHANGELOG.md"

tag="${1:-}"
[[ "$tag" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    echo "usage: $(basename "$0") <major.minor.patch> [--dry-run] [--rev <sha>] [--no-verify]" >&2
    exit 2
}
shift

dry_run=false
verify=true
rev="HEAD"
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) dry_run=true ;;
        --no-verify) verify=false ;;
        --rev) rev="${2:?--rev needs a revision}"; shift ;;
        *) echo "error: unknown option $1" >&2; exit 2 ;;
    esac
    shift
done

ok() { printf '  \xe2\x9c\x93 %s\n' "$1"; }
note() { printf '  - %s\n' "$1"; }
die() { printf '\n  error: %s\n' "$1" >&2; exit 1; }

echo
echo "  LagoonEngine ${tag}"
echo

# 1. The constant and the tag are one number in two places, and SwiftPM only
#    knows the tag.
declared="$(grep -m1 -oE 'current = "[0-9]+\.[0-9]+\.[0-9]+"' "$version_file" \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')" \
    || die "could not read EngineVersion.current from ${version_file#$root/}"
[ "$declared" = "$tag" ] \
    || die "EngineVersion.current is ${declared}, not ${tag}. Set it, commit, then tag."
ok "EngineVersion.current says ${tag}"

# 2. The release body comes from the changelog, so GitHub says what the
#    repository says.
notes="$(awk -v v="## ${tag}" '
    $0 == v { found = 1; next }
    found && /^## / { exit }
    found { print }
' "$changelog")"
[ -n "$(printf '%s' "$notes" | tr -d '[:space:]')" ] \
    || die "CHANGELOG.md has no entry for ${tag}"
ok "changelog entry read for ${tag}"

# 3. gh tags through the API, so the revision must already be on the remote.
#    Catches an unpushed main.
sha="$(git -C "$root" rev-parse --verify "${rev}^{commit}")" \
    || die "cannot resolve revision ${rev}"
git -C "$root" fetch --quiet origin || die "could not reach origin"
git -C "$root" merge-base --is-ancestor "$sha" origin/main 2>/dev/null \
    || die "${rev} (${sha:0:9}) is not on origin/main yet. Push before releasing."
ok "${sha:0:9} is on origin/main"

# 4. Re-tagging is the one thing that cannot be undone cleanly.
! git -C "$root" rev-parse -q --verify "refs/tags/${tag}" >/dev/null \
    || die "${tag} already exists locally"
[ -z "$(git -C "$root" ls-remote --tags origin "refs/tags/${tag}" 2>/dev/null)" ] \
    || die "${tag} already exists on the remote"
ok "${tag} is unused"

slug="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)" \
    || die "this checkout has no GitHub remote gh can resolve"
ok "releasing into ${slug}"

# 5. The vendored frameworks carry their own terms, so the materials must be
#    in the tree. GitHub's source archive holds them, but not FFmpeg's source,
#    which the LGPL wants offered from the same place as the binaries: the
#    release attaches that bundle (step 8).
missing=""
for material in LICENSE Artifacts/FFmpeg.README.md Artifacts/Libdovi.README.md; do
    git -C "$root" cat-file -e "${sha}:${material}" 2>/dev/null || missing="${missing} ${material}"
done
[ -z "$missing" ] || die "the revision is missing dependency materials:${missing}"
ok "licence and provenance materials are in the archive"

# 6. People read the codec table to decide whether this plays their media, so
#    it must not be stale.
if [ "$verify" = true ]; then
    "$root/scripts/generate-codec-support.sh" --check >/dev/null 2>&1 \
        || die "docs/codec-support.md is out of date. Run scripts/generate-codec-support.sh"
    ok "docs/codec-support.md is current"
fi

# 7. The costly guard: a tag a consumer cannot build.
if [ "$verify" = true ]; then
    note "building and testing both platforms, which takes a few minutes"
    for destination in \
        "generic/platform=tvOS Simulator" \
        "generic/platform=iOS Simulator"; do
        xcodebuild -scheme LagoonEngine -destination "$destination" build >/dev/null 2>&1 \
            || die "the package does not build for ${destination#generic/platform=}"
    done
    ok "builds for tvOS and iOS"
    xcodebuild test -scheme LagoonEngine \
        -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)' \
        >/dev/null 2>&1 || die "the test suite does not pass"
    ok "the test suite passes"
else
    note "skipping the build and test gate"
fi

# 8. FFmpeg's corresponding source, attached to the release it belongs to.
bundle_dir="$(mktemp -d)"
trap 'rm -rf "$bundle_dir"' EXIT
bundle="$("$root/scripts/ffmpeg-source-bundle.sh" "$tag" "$bundle_dir" --rev "$sha")" \
    || die "could not assemble the FFmpeg source bundle"
ok "FFmpeg source bundle: $(basename "$bundle")"

# Below 1.0 is a pre-release, so an unfinished API is never served as Latest.
set -- gh release create "$tag" "$bundle" --repo "$slug" --target "$sha" \
    --title "$tag" --notes-file -
case "$tag" in 0.*) set -- "$@" --prerelease ;; esac

echo
if [ "$dry_run" = true ]; then
    echo "  would run: $*"
    echo
    echo "  with this body:"
    printf '%s\n' "$notes" | sed 's/^/      /'
    echo
    echo "  (dry run, nothing was tagged or published)"
    exit 0
fi

printf '%s\n' "$notes" | "$@"
echo
echo "  Fetch the tag it created: git fetch --tags origin"
