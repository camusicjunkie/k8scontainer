#!/usr/bin/env bash
# Mechanical checks on README.md and docs/*.md: (1) no GLOSSARY.md _Avoid_ term in prose,
# (2) every repo path cited in backticks exists, (3) every script/command named
# in backticks that this repo ships exists. Run from anywhere: docs/check.sh
set -uo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo" || exit 1
docs=(README.md docs/admin-guide.md docs/release-owner-guide.md docs/e2e-checklist.md)
fail=0
flag=$(mktemp -u)
bad() { echo "FAIL $*"; fail=1; }

# Prose = the docs without fenced blocks and inline code spans.
prose() { awk '/^ *```/{f=!f; next} !f' "$1" | sed 's/`[^`]*`//g'; }

# 1. Avoid terms from GLOSSARY.md (_Avoid_ lines), plus "devcontainer" on its own.
mapfile -t avoid < <(grep '^_Avoid_:' GLOSSARY.md | sed 's/^_Avoid_: *//; s/ (on its own)//' | tr ',' '\n' | sed 's/^ *//; s/ *$//' | grep -v '^$')
for d in "${docs[@]}"; do
    for t in "${avoid[@]}"; do
        if [[ $t == devcontainer ]]; then
            # bare "devcontainer": not part of a Devcontainer Pod/Namespace term or a name
            prose "$d" | grep -inE '\bdevcontainer\b' | grep -ivE 'devcontainer (pod|namespace)|devcontainer-|devcontainer/|Host devcontainer|^[0-9]+:.*named .devcontainer' | sed "s|^|$d: |" | while read -r l; do echo "FAIL bare 'devcontainer': $l"; touch "$flag"; done
        else
            prose "$d" | grep -inE "\b$t\b" | sed "s|^|$d: |" | while read -r l; do echo "FAIL avoided term '$t': $l"; touch "$flag"; done
        fi
    done
done

# 2/3. Backticked tokens that look like repo paths or shipped commands.
for d in "${docs[@]}"; do
    while read -r tok; do
        p=${tok%%[ ,:;)]*}
        p=${p%/}
        case $p in
            *'<'* | *'*'* | http* | /* | '~'* | harbor.example* | out/*) continue ;;
        esac
        if [[ $p =~ ^(docs|image|release|workstation|manifests|tests|\.scratch)/ || $p =~ ^(GLOSSARY\.md|AGENTS\.md|\.gitlab-ci\.yml)$ ]]; then
            [[ -e $p ]] || bad "$d cites missing path: $p"
        fi
    done < <(grep -o '`[^`]*`' "$d" | tr -d '`' | sort -u)
done

# Shipped commands the docs name, by their bare names.
for c in secrets with-secrets klogin devc-selftest devc-sshd devc-ca-refresh; do
    [[ -e image/rootfs/usr/local/bin/$c ]] || bad "no image command $c"
done
for f in image/rootfs/etc/profile.d/20-config-env.sh image/packages/vscode.env image/packages/vscode-extensions.txt \
         release/cut.sh release/import.sh workstation/install.ps1 workstation/settings.json \
         tests/image.sh tests/cluster.sh tests/release.sh tests/secrets-klogin.sh workstation/tests/install.Tests.ps1; do
    [[ -e $f ]] || bad "missing $f"
done

# Facts cited in the docs that must match the code.
grep -q 'DHI_BASE' image/Dockerfile || bad "DHI_BASE not in image/Dockerfile"
grep -q 'HARBOR_IMAGE' .gitlab-ci.yml && grep -q 'HARBOR_USER' .gitlab-ci.yml && grep -q 'HARBOR_PASSWORD' .gitlab-ci.yml || bad "CI variable names differ from .gitlab-ci.yml"
grep -q 'OnDelete' manifests/devcontainer/resourceset.yaml || bad "OnDelete not in resourceset"
grep -q '">=0.1.0"' manifests/devcontainer/image-automation.yaml || bad "ImagePolicy range differs from docs"
grep -q 'imagepolicy": "devcontainer:devcontainer-standard:tag' manifests/devcontainer/roster.yaml || bad "marker differs from docs"
grep -q 'ms-vscode-remote.remote-ssh' workstation/install.ps1 || bad "Remote-SSH id differs"
grep -q 'state-devc\|name: state' manifests/devcontainer/resourceset.yaml || bad "volume claim name differs"
grep -q 'DEVC_UNLOCK_KEY' image/rootfs/usr/local/lib/devc/secrets.bash || bad "DEVC_UNLOCK_KEY missing"
# Personal Config: the bashrc the image sources is on the path the Pod mounts.
grep -q 'mountPath: /home/dev/.devc/personal' manifests/devcontainer/resourceset.yaml || bad "Pod does not mount Personal Config at ~/.devc/personal"
grep -q '\$HOME/.devc/personal/bashrc' image/rootfs/etc/bash.bashrc.d/99-personal.sh || bad "99-personal.sh does not read ~/.devc/personal/bashrc"
! grep -rq '/etc/devcontainer/personal' image manifests docs/*.md || bad "stale /etc/devcontainer/personal path"

[[ -e $flag ]] && { fail=1; rm -f "$flag"; }
((fail)) && { echo "docs check FAILED"; exit 1; }
echo "docs check passed"
