#!/usr/bin/env bash
# brew-check.sh IN OUT: decides what of the brew builder stage's output may
# enter the Standard Image. Runs on the DHI base, so the loader and
# glibc it checks against are the ones the image will use.
#
# A binary may be static, or linked only against glibc's own libraries: Homebrew
# builds many Go tools with cgo and points them at its own loader, so those are
# moved onto the system loader with brew's RPATH removed. Anything that needs
# another library, or a script run by something under the brew prefix, fails
# the build with its name. Each rewritten binary is checked again afterwards.
set -euo pipefail

in=$1 out=$2
glibc=" libc.so.6 libm.so.6 libgcc_s.so.1 ld-linux-x86-64.so.2 libpthread.so.0 libdl.so.2 librt.so.1 libresolv.so.2 "
loader=/lib64/ld-linux-x86-64.so.2
failed=()

# verify_patched FILE: the rewrite must have left FILE on the system loader with
# no RPATH or RUNPATH and only glibc libraries (patchelf can fail quietly).
verify_patched() {
    local f=$1 lib
    [[ $(patchelf --print-interpreter "$f") == "$loader" ]] || { echo "interpreter is not $loader"; return 1; }
    [[ -z $(patchelf --print-rpath "$f") ]] || { echo "still has an RPATH or RUNPATH"; return 1; }
    while IFS= read -r lib; do
        [[ $glibc == *" $lib "* ]] || { echo "needs $lib"; return 1; }
    done < <(patchelf --print-needed "$f")
}

mkdir -p "$out/bin" "$out/completions"
shopt -s nullglob
for f in "$in"/bin/*; do
    name=${f##*/}
    if [[ $(head -c4 "$f") != $'\x7fELF' ]]; then
        if head -n1 "$f" | grep -q linuxbrew; then
            failed+=("$name: a script run by the brew prefix ($(head -n1 "$f"))")
        else
            install -m 0755 "$f" "$out/bin/$name"
        fi
        continue
    fi
    if ! patchelf --print-interpreter "$f" >/dev/null 2>&1; then
        install -m 0755 "$f" "$out/bin/$name" # static
        continue
    fi
    bad=()
    while IFS= read -r lib; do
        [[ $glibc == *" $lib "* ]] || bad+=("$lib")
    done < <(patchelf --print-needed "$f")
    if ((${#bad[@]})); then
        failed+=("$name: dynamically linked against brew libraries: ${bad[*]}")
        continue
    fi
    install -m 0755 "$f" "$out/bin/$name"
    patchelf --set-interpreter "$loader" --remove-rpath "$out/bin/$name"
    if ! why=$(verify_patched "$out/bin/$name"); then
        failed+=("$name: still not on the system loader after patching: $why")
    fi
done

if ((${#failed[@]})); then
    printf 'brew-check: %s\n' "${failed[@]}" >&2
    echo "brew-check: these can't come from brew; take them from apt or their own installer" >&2
    exit 1
fi

cp -r "$in/completions/." "$out/completions/"
cp "$in/brew-versions.txt" "$out/brew-versions.txt"
