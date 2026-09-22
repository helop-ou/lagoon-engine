#!/usr/bin/env bash
#
# Regenerates docs/codec-support.md from EngineCodecSupport.
#
# The table is generated rather than written because a hand-maintained list
# drifts from the routing switches the moment somebody adds a codec, and a
# published table that overstates what plays is worse than none. Generating it
# means the document is by construction the same set the demuxer and the
# software decoder agree on — the tests beside the renderer pin it to both.
#
# The renderer lives in the test target because that is the only place with
# access to the table. It prints the document between two markers rather than
# writing a file: a package test target runs in a generic runner whose
# container is cleared when the run ends, so a path reported from inside it
# points at nothing by the time this script looks.
#
#   scripts/generate-codec-support.sh           # regenerate the document
#   scripts/generate-codec-support.sh --check   # fail if it is out of date
#
# Override the simulator with LAGOON_CODEC_DOC_DESTINATION.
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
awk '/^CODEC_SUPPORT_DOC_BEGIN$/ { on = 1; next }
     /^CODEC_SUPPORT_DOC_END$/   { exit }
     on' "$log" > "$generated"
if [ ! -s "$generated" ]; then
    echo "error: the generator printed no document" >&2
    tail -40 "$log" >&2
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
