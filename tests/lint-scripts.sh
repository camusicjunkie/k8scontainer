#!/bin/sh
# Which files tests/lint.sh hands to shellcheck: runs `tests/lint.sh scripts`
# in a scratch git repository with known files and compares the list.
#
#   tests/lint-scripts.sh
#
# POSIX sh and git only, so the pipeline's shellcheck job runs it before the
# lint, and tests/all.sh --files runs it where git is installed.
set -eu
repo=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/tests" "$tmp/bin" "$tmp/.claude/worktrees/w"
cp "$repo/tests/lint.sh" "$tmp/tests/lint.sh"
cd "$tmp"
printf '#!/usr/bin/env bash\n' > a.sh
printf 'echo no shebang\n' > b.sh
printf '#!/bin/bash\n' > bin/bash-abs
printf '#!/usr/bin/env -S bash -eu\n' > bin/env-s
printf '#!/bin/dash\n' > bin/dash
printf '#!/bin/sh\r\necho crlf\r\n' > bin/crlf
printf '#!/usr/bin/env python3\n' > bin/python
printf '#!/bin/shx\n' > bin/shx
printf 'plain text\n' > README
# Not tracked: an agent's worktree and a loose script.
printf '#!/bin/sh\n' > .claude/worktrees/w/nested.sh
printf '#!/bin/sh\n' > loose.sh
git init --quiet .
git -c core.autocrlf=false add a.sh b.sh bin README tests

want='a.sh
b.sh
bin/bash-abs
bin/crlf
bin/dash
bin/env-s
tests/lint.sh'
got=$(sh tests/lint.sh scripts)
if [ "$got" = "$want" ]; then
    echo "ok   tests/lint.sh lists the tracked *.sh files and sh, bash and dash shebangs (env -S, CRLF), nothing untracked"
else
    echo "FAIL tests/lint.sh scripts listed:"
    echo "$got" | sed 's/^/    /'
    echo "  wanted:"
    echo "$want" | sed 's/^/    /'
    exit 1
fi
