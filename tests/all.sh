#!/usr/bin/env bash
# Every check in the repo, in one command:
#
#   tests/all.sh           every check this machine can run
#   tests/all.sh --files   only the file checks (what the pipeline's `checks` job runs)
#
# The file checks (tests/ci.py, tests/repo.py, docs/check.sh) always run; they
# need only bash and python3 with PyYAML. Each seam that needs tools runs only when they are present, and is
# reported as SKIP otherwise, so a green run here says what it did not cover.
set -uo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo" || exit 1
py=python3; python3 -c "" >/dev/null 2>&1 || py=python
failed=() skipped=()

run() { # run NAME COMMAND...
    local name=$1; shift
    echo "== $name"
    if "$@"; then echo "PASS $name"; else echo "FAIL $name"; failed+=("$name"); fi
}
skip() { echo "SKIP $1 (needs $2)"; skipped+=("$1"); }
has() { command -v "$1" >/dev/null; }
docker_up() { has docker && docker info >/dev/null 2>&1; }

run tests/ci.py "$py" tests/ci.py
run tests/repo.py "$py" tests/repo.py
run docs/check.sh bash docs/check.sh

if [[ ${1:-} == --files ]]; then :
else
    if docker_up; then
        run tests/image.sh bash tests/image.sh
        run tests/release.sh bash tests/release.sh
        run tests/secrets-klogin.sh bash tests/secrets-klogin.sh
    else
        for s in tests/image.sh tests/release.sh tests/secrets-klogin.sh; do skip "$s" "a running Docker"; done
    fi
    # tests/cluster.sh starts the image tests/image.sh just built; after a failed
    # build it would test whatever stale devc-standard:test is left over.
    if [[ " ${failed[*]} " == *" tests/image.sh "* ]]; then
        skip tests/cluster.sh "the image tests/image.sh failed to build or pass"
    elif docker_up && has kubectl && has flux-operator; then
        run tests/cluster.sh bash tests/cluster.sh
    else
        skip tests/cluster.sh "Docker, kubectl and the flux-operator CLI"
    fi
    if has pwsh && pwsh -NoProfile -c 'exit [int]!(Get-Module -ListAvailable Pester | ? { $_.Version.Major -ge 5 })' 2>/dev/null; then
        run workstation/tests pwsh -NoProfile -c 'exit (Invoke-Pester workstation/tests -PassThru).FailedCount'
    else
        skip workstation/tests "pwsh with Pester 5"
    fi
fi

echo
((${#skipped[@]})) && echo "skipped: ${skipped[*]}"
if ((${#failed[@]})); then echo "failed: ${failed[*]}"; exit 1; fi
echo "all run checks passed"
