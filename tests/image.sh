#!/usr/bin/env bash
# Image seam: builds the Standard Image and runs its self-test against it from
# outside, with no network, as the image's own user.
#
#   tests/image.sh            build, then run every case
#   IMAGE=tag tests/image.sh  skip the build and test an existing image
set -uo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
image=${IMAGE:-}
failed=()

pass() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; failed+=("$1"); }

if [[ -z $image ]]; then
    image=devc-standard:test
    docker build --tag "$image" "$repo/image" || { echo "image.sh: the build failed" >&2; exit 1; }
fi

offline() { docker run --rm --network none "$@"; }

# The image's configured user is not root.
user=$(docker inspect --format '{{.Config.User}}' "$image")
if [[ -n $user && $user != 0 && $user != root && $user != 0:* && $user != root:* ]]; then
    pass "the image's user is $user, not root"
else
    fail "the image's user is not root (got '${user:-unset}')"
fi

# The self-test passes offline as that user.
if out=$(offline "$image" devc-selftest 2>&1); then
    pass "the self-test passes with no network"
else
    fail "the self-test passes with no network"
    printf '%s\n' "$out" | tail -n 40
fi

# The self-test fails, naming the problem, when started as root.
if out=$(offline --user 0 --entrypoint devc-selftest "$image" 2>&1); then
    fail "the self-test fails when run as root"
elif grep -q 'FAIL .*not root' <<<"$out"; then
    pass "the self-test fails when run as root"
else
    fail "the self-test fails for the wrong reason as root: $(tail -n 3 <<<"$out")"
fi

# The entrypoint refuses to start anything as root.
if out=$(offline --user 0 "$image" true 2>&1); then
    fail "the entrypoint refuses to start as root"
elif grep -q 'root' <<<"$out"; then
    pass "the entrypoint refuses to start as root"
else
    fail "the entrypoint failed without naming root: $out"
fi

# No sudo.
if offline --entrypoint bash "$image" -c '! command -v sudo' >/dev/null 2>&1; then
    pass "sudo is not installed"
else
    fail "sudo is not installed"
fi

# The Docker CLI is gone.
if offline --entrypoint bash "$image" -c '! command -v docker' >/dev/null 2>&1; then
    pass "the Docker CLI is not installed"
else
    fail "the Docker CLI is not installed"
fi

if ((${#failed[@]})); then
    printf '%d case(s) failed\n' "${#failed[@]}"
    exit 1
fi
echo "all cases passed"
