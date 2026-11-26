# shellcheck shell=bash
# The image itself: which Release it is, and no way to gain privileges.

check "release MANIFEST has a version" test -n "$(manifest_value version)"
check "release MANIFEST has a git SHA" test -n "$(manifest_value git_sha)"
check "sudo is not installed" bash -c '! command -v sudo'
check "the container user is not root" bash -c 'test "$(id -u)" -ne 0 && test "$(id -g)" -ne 0'
check "no process-level capabilities are held" bash -c '! grep -qE "^CapEff:\s+0*[1-9a-f]" /proc/self/status'
