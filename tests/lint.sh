#!/bin/sh
# Lint seam: shellcheck on every shell script, hadolint on the Standard Image's
# Dockerfile.
#
#   tests/lint.sh shellcheck
#   tests/lint.sh hadolint
#   tests/lint.sh scripts      list the files shellcheck gets
#   tests/lint.sh linters      list the linters, one per line
#
# POSIX sh, so the pipeline runs it straight from the linters' own images
# (alpine and debian, neither with bash). tests/all.sh runs each linter only
# when it is installed.
set -eu
cd "$(dirname "$0")/.."

# The one list of linters: tests/all.sh runs these, and tests/ci.py reads this
# line for the pipeline jobs it expects.
LINTERS="shellcheck hadolint"

# A shell script is a tracked *.sh file or a tracked file whose shebang names
# sh, bash or dash (directly or through env, -S too), which catches the
# extensionless commands under image/rootfs/usr/local/bin. git ls-files, not
# find, so untracked trees (an agent's .claude/worktrees) are left alone. The
# CR is dropped so a CRLF script is found, and shellcheck reports its endings.
shell_scripts() {
    git -c safe.directory="$PWD" -c core.quotepath=off ls-files | sort | while IFS= read -r f; do
        [ -f "$f" ] || continue
        case $f in
            *.sh) echo "$f" ;;
            *) if head -n 1 "$f" | tr -d '\r' | grep -Eq '^#! *(/usr)?/bin/(env +(-S +)?)?(ba|da)?sh( |$)'; then echo "$f"; fi ;;
        esac
    done
}

# The release in HADOLINT_IMAGE's tag, e.g. 2.15.1 from hadolint:v2.15.1-debian@...
pinned_hadolint() {
    sed -n 's/^ARG HADOLINT_IMAGE=[^:]*:v\{0,1\}\([0-9][0-9.]*\).*/\1/p' image/Dockerfile
}

case ${1:-} in
scripts)
    shell_scripts
    ;;
linters)
    printf '%s\n' $LINTERS
    ;;
shellcheck)
    list=$(shell_scripts)
    [ -n "$list" ] || { echo "no shell scripts found" >&2; exit 1; }
    echo "shellcheck $(shellcheck --version | sed -n 's/^version: //p') on $(echo "$list" | wc -l | tr -d ' ') scripts"
    # Warning severity: at info level SC2317 flags every function the scripts
    # call indirectly (traps, dispatch tables) as unreachable. The scripts'
    # `# shellcheck source=` directives are relative to the script itself.
    echo "$list" | tr '\n' '\0' | xargs -0 shellcheck --severity=warning --external-sources --source-path=SCRIPTDIR
    ;;
hadolint)
    want=$(pinned_hadolint)
    [ -n "$want" ] || { echo "no version in image/Dockerfile's HADOLINT_IMAGE" >&2; exit 1; }
    have=$(hadolint --version | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
    # Older releases reject the Dockerfile's ADD --checksum outright.
    [ "$have" = "$want" ] || { echo "hadolint is $have; image/Dockerfile's HADOLINT_IMAGE pins $want" >&2; exit 1; }
    echo "hadolint $have on image/Dockerfile"
    hadolint image/Dockerfile
    ;;
*)
    echo "usage: tests/lint.sh shellcheck|hadolint|scripts|linters" >&2
    exit 2
    ;;
esac
