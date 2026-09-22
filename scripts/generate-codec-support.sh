#!/usr/bin/env bash
#
# Regenerates docs/codec-support.md from EngineCodecSupport.
#
#   scripts/generate-codec-support.sh           # regenerate the document
#   scripts/generate-codec-support.sh --check   # fail if it is out of date
#
# Override the simulator with LAGOON_CODEC_DOC_DESTINATION.
#
# Generated so the table cannot drift from what the demuxer and software
# decoder accept; tests pin it to both. The renderer lives in the test target,
# the only place with access to the table, and prints the document because the
# test runner's container is cleared when the run ends. Each line has its own
# markers because runner output lands inside printed lines.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
target="$repo/docs/codec-support.md"
destination="${LAGOON_CODEC_DOC_DESTINATION:-platform=tvOS Simulator,name=Apple TV 4K (3rd generation),OS=latest}"

check=false
[ "${1:-}" = "--check" ] && check=true

log="$(mktemp)"
trap 'rm -f "$log"' EXIT

if ! xcodebuild test \
    -scheme LagoonEngine \
    -destination "$destination" \
    -only-testing:LagoonEngineTests/CodecSupportDocTests \
    >"$log" 2>&1; then
    echo "error: the generator test failed" >&2
    tail -40 "$log" >&2
    exit 1
fi

generated="$(mktemp)"
trap 'rm -f "$log" "$generated"' EXIT
# Keep only what lies between a line's own markers, trimming runner output.
awk '
    { start = index($0, "CODEC_DOC|") }
    start == 0 { next }
    {
        rest = substr($0, start + 10)
        stop = index(rest, "|CODEC_DOC")
    }
    stop == 0 { next }
    { print substr(rest, 1, stop - 1) }
' "$log" > "$generated"
if [ ! -s "$generated" ]; then
    echo "error: the generator printed no document" >&2
    tail -40 "$log" >&2
    exit 1
fi

# A line lost to interleaving would silently truncate the document, so check
# the shape first.
if [ "$(head -1 "$generated")" != "# Codec support" ] \
    || ! grep -q '^## Audio$' "$generated" \
    || ! grep -q '^## Interlacing$' "$generated"; then
    echo "error: the extracted document is not shaped like the codec table" >&2
    echo "       the runner's output may have interleaved past trimming" >&2
    exit 1
fi

if [ "$check" = true ]; then
    if diff -u "$target" "$generated"; then
        echo "docs/codec-support.md is current"
    else
        echo >&2
        echo "error: docs/codec-support.md is out of date. Run scripts/generate-codec-support.sh" >&2
        exit 1
    fi
else
    cp "$generated" "$target"
    echo "wrote docs/codec-support.md ($(wc -l < "$target" | tr -d ' ') lines)"
fi
