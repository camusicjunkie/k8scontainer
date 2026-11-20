#!/usr/bin/env bash
# brew-export.sh LIST OUT: runs in the brew builder stage. Installs every formula
# in LIST (latest at build time, ADR 0001) and exports their binaries, bash
# completions and `brew list --versions` to OUT for brew-check.sh. Nothing else
# of brew leaves this stage.
set -euo pipefail

list=$1 out=$2
mapfile -t formulae < <(grep -vE '^[[:space:]]*(#|$)' "$list")

brew update --quiet
for tap in $(printf '%s\n' "${formulae[@]}" | awk -F/ 'NF == 3 { print $1 "/" $2 }' | sort -u); do
    brew tap "$tap"
done
HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 brew install --quiet "${formulae[@]}"

mkdir -p "$out/bin" "$out/completions"
: >"$out/brew-versions.txt"
for formula in "${formulae[@]}"; do
    name=${formula##*/}
    dir=$(brew --prefix "$name")
    for f in "$dir"/bin/*; do
        cp "$(readlink -f "$f")" "$out/bin/${f##*/}"
    done
    for c in "$dir"/etc/bash_completion.d/* "$dir"/share/bash-completion/completions/*; do
        [[ -f $c ]] && cp "$(readlink -f "$c")" "$out/completions/${c##*/}"
    done
    brew list --versions "$name" >>"$out/brew-versions.txt"
done
