# shellcheck shell=bash
# Shared by the tests/*.sh seams: the pass/fail/check helpers and the failure
# list. Source it after `set -uo pipefail`.
failed=()

pass() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; failed+=("$1"); }
check() { # check DESCRIPTION COMMAND...
    local d=$1; shift
    if "$@"; then pass "$d"; else fail "$d"; fi
}
