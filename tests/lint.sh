#!/bin/sh
# Lint seam: shellcheck on every shell script, hadolint on the Standard Image's
# Dockerfile.
#
#   tests/lint.sh shellcheck
#   tests/lint.sh hadolint
#
# POSIX sh, so the pipeline runs it straight from the linters' own images
# (alpine and debian, neither with bash). tests/all.sh runs each linter only
# when it is installed.
set -eu
cd "$(dirname "$0")/.."

# A shell script is a *.sh file or a file whose shebang names sh or bash, which
# catches the extensionless commands under image/rootfs/usr/local/bin.
shell_scripts() {
    find . -path ./.git -prune -o -type f -print | sort | while IFS= read -r f; do
        case $f in
            *.sh) echo "$f" ;;
            *) if head -n 1 "$f" | grep -Eq '^#! *(/usr)?/bin/(env +)?(ba)?sh( |$)'; then echo "$f"; fi ;;
        esac
    done
}

# The release in HADOLINT_IMAGE's tag, e.g. 2.15.1 from hadolint:v2.15.1-debian@...
pinned_hadolint() {
    sed -n 's/^ARG HADOLINT_IMAGE=[^:]*:v\{0,1\}\([0-9][0-9.]*\).*/\1/p' image/Dockerfile
}

case ${1:-} in
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
    echo "usage: tests/lint.sh shellcheck|hadolint" >&2
    exit 2
    ;;
esac
