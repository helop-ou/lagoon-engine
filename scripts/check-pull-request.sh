#!/usr/bin/env bash
#
# See CONTRIBUTING.md, "Pull requests". Locally:
#
#   BRANCH=fix/home-rows TITLE="fix: show the rows" BODY=$'Changes:\n- Show the rows' \
#   BASE=origin/main HEAD=HEAD scripts/check-pull-request.sh
set -uo pipefail

types='feat|fix|docs|test|refactor|perf|build|chore|ci|style|revert'
references='(^|[^A-Za-z0-9])(HEL|LAGOON)-[0-9]+|sentry\.io|atlassian\.net'

problems=0
problem() {
    echo "✘ $*"
    problems=$((problems + 1))
}

branch="${BRANCH:-}"
if ! [[ "$branch" =~ ^($types)/[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
    problem "Branch \"$branch\" should be <type>/<kebab-case-words>, with a type of: ${types//|/, }"
fi

title="${TITLE:-}"
if ! [[ "$title" =~ ^($types):\ [^A-Z\ ] ]]; then
    problem "Title \"$title\" should start with \"<type>: \" and a lowercase word, like a commit subject"
fi
if (( ${#title} > 72 )); then
    problem "Title is ${#title} characters, over the 72 allowed"
fi
if [[ "$title" == *. ]]; then
    problem "Title ends with a full stop"
fi

body="$(printf '%s' "${BODY:-}" | tr -d '\r' | sed -e '/^[[:space:]]*$/d')"
if [[ "$(printf '%s\n' "$body" | head -n 1)" != "Changes:" ]]; then
    problem "Description should start with a \"Changes:\" line"
fi
if ! printf '%s\n' "$body" | sed -n '2,$p' | grep -q '^- '; then
    problem "Description should list at least one change as \"- …\""
fi
if printf '%s\n' "$body" | sed -n '2,$p' | grep -qv '^- '; then
    problem "Description should hold only \"- …\" lines after \"Changes:\""
fi

if printf '%s\n%s\n' "$title" "$body" | grep -qE "$references"; then
    problem "Title or description mentions a Sentry issue or Jira ticket"
fi

if [[ -n "${BASE:-}" && -n "${HEAD:-}" ]]; then
    commits="$(git rev-list --no-merges "$BASE..$HEAD")" || {
        problem "Could not list the commits between $BASE and $HEAD"
        commits=""
    }
    for commit in $commits; do
        short="$(git rev-parse --short "$commit")"
        subject="$(git log -1 --format=%s "$commit")"
        rest="$(git log -1 --format=%b "$commit" | sed -e '/^[[:space:]]*$/d')"
        if ! [[ "$subject" =~ ^($types):\ [^A-Z\ ] ]]; then
            problem "Commit $short \"$subject\" should be \"<type>: <lowercase start>\""
        fi
        if [[ -n "$rest" ]]; then
            problem "Commit $short has a body or trailer, but commits are a subject line only"
        fi
        if printf '%s\n%s\n' "$subject" "$rest" | grep -qE "$references"; then
            problem "Commit $short mentions a Sentry issue or Jira ticket"
        fi
    done
fi

if (( problems > 0 )); then
    echo "$problems problem(s). See CONTRIBUTING.md, \"Pull requests\"."
    exit 1
fi
echo "✔ Branch, title, description and commits follow the conventions"
