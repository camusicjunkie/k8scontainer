#!/usr/bin/env bash
# Release seam: cuts a Release from a tagged image in a registry, then imports
# it into a second registry, checking what the Release Owner can observe.
#
#   tests/release.sh
#
# Needs Docker. Runs two throwaway registry:2 containers (the Connected and the
# Disconnected Harbor stand-ins) and runs release/cut.sh and release/import.sh
# inside the pinned skopeo image, as the pipeline does.
set -uo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib.sh
source "$repo/tests/lib.sh"
skopeo_image=quay.io/skopeo/stable:v1.25.1
net=devc-rel-test-$$
work=$(mktemp -d)


# Docker on Windows wants native paths for bind mounts.
native() { if command -v cygpath >/dev/null; then cygpath -w "$1"; else echo "$1"; fi; }
export MSYS_NO_PATHCONV=1

cleanup() {
    docker rm -f "devc-rel-conn-$$" "devc-rel-disc-$$" >/dev/null 2>&1
    docker network rm "$net" >/dev/null 2>&1
    rm -rf "$work"
}
trap cleanup EXIT

# in_skopeo CMD...: runs CMD in the skopeo image on the test network with the
# scratch dir at /work (release/ is copied into it).
in_skopeo() {
    docker run --rm --network "$net" -e DEVC_INSECURE=1 \
        -v "$(native "$work"):/work" \
        --entrypoint "$1" "$skopeo_image" "${@:2}"
}
sk() { in_skopeo skopeo --tls-verify=false "$@"; }

docker network create "$net" >/dev/null || exit 1
docker run -d --name "devc-rel-conn-$$" --network "$net" registry:2 >/dev/null || exit 1
docker run -d --name "devc-rel-disc-$$" --network "$net" registry:2 >/dev/null || exit 1
conn=devc-rel-conn-$$:5000
disc=devc-rel-disc-$$:5000
sleep 2

# A tagged image on the Connected Side, in OCI format as buildah produces it.
mkdir -p "$work/src" "$work/out" "$work/release"
cp "$repo"/release/*.sh "$work/release/"
printf 'FROM scratch\nCOPY marker /marker\nLABEL org.opencontainers.image.version="1.2.3" org.opencontainers.image.revision="0123abc"\n' \
    >"$work/src/Dockerfile"
echo "release test $$" >"$work/src/marker"
docker build -q -t devc-rel-src:$$ "$(native "$work/src")" >/dev/null || exit 1
docker save devc-rel-src:$$ -o "$(native "$work/src.tar")" && docker rmi devc-rel-src:$$ >/dev/null
sk copy --format oci docker-archive:/work/src.tar "docker://$conn/standard:1.2.3" >/dev/null || { echo "setup failed" >&2; exit 1; }
src_digest=$(sk inspect --format '{{.Digest}}' "docker://$conn/standard:1.2.3")

# --- cut ---------------------------------------------------------------------
in_skopeo bash /work/release/cut.sh "$conn/standard:1.2.3" 1.2.3 /work/out >"$work/cut.log" 2>&1
check "cut succeeds from a tagged image" test $? -eq 0
tail -n 5 "$work/cut.log"

archive=$work/out/devcontainer-1.2.3.oci.tar
check "cut writes the archive" test -s "$archive"
check "cut writes a checksum that verifies the archive" \
    bash -c "cd '$work/out' && sha256sum -c devcontainer-1.2.3.oci.tar.sha256 >/dev/null"
packet=$work/out/review-1.2.3/SUMMARY.md
check "cut writes the Review Packet" test -s "$packet"
check "the Review Packet names the version, checksum and image digest" bash -c "
    grep -q '1.2.3' '$packet' &&
    grep -q \"\$(cut -d' ' -f1 '$work/out/devcontainer-1.2.3.oci.tar.sha256')\" '$packet' &&
    grep -q '$src_digest' '$packet'"
check "the Review Packet carries the image's version and revision labels" bash -c "
    grep -qx -- '- version: 1.2.3' '$packet' && grep -qx -- '- revision: 0123abc' '$packet'"

in_skopeo bash /work/release/cut.sh "$conn/standard:1.2.3" 1.2.3 /work/out >/dev/null 2>&1
check "cut refuses to overwrite an existing Release" test $? -ne 0
in_skopeo bash /work/release/cut.sh "$conn/standard:1.2.3" latest /work/out >/dev/null 2>&1
check "cut refuses a version that is not X.Y.Z" test $? -ne 0

# --- import ------------------------------------------------------------------
# A corrupted copy of the Release, as if damaged in transfer.
mkdir -p "$work/bad"
cp "$work/out/devcontainer-1.2.3.oci.tar" "$work/out/devcontainer-1.2.3.oci.tar.sha256" "$work/bad/"
printf 'x' >>"$work/bad/devcontainer-1.2.3.oci.tar"
in_skopeo bash /work/release/import.sh /work/bad/devcontainer-1.2.3.oci.tar "$disc/standard:1.2.3" >"$work/bad.log" 2>&1
check "import refuses a checksum mismatch" test $? -ne 0
grep -qi 'checksum' "$work/bad.log"
check "the refusal says the checksum failed" test $? -eq 0
sk inspect "docker://$disc/standard:1.2.3" >/dev/null 2>&1
check "a refused import pushes nothing" test $? -ne 0

in_skopeo bash /work/release/import.sh /work/out/devcontainer-1.2.3.oci.tar "$disc/standard:1.2.3" >"$work/imp.log" 2>&1
check "import succeeds on an intact Release" test $? -eq 0
tail -n 3 "$work/imp.log"
dst_digest=$(sk inspect --format '{{.Digest}}' "docker://$disc/standard:1.2.3")
check "the imported image has the source digest" test "$dst_digest" = "$src_digest"

in_skopeo bash /work/release/import.sh /work/out/devcontainer-1.2.3.oci.tar "$disc/standard:1.2.3" >"$work/again.log" 2>&1
check "import refuses to overwrite an existing version" test $? -ne 0
check "the existing version is left untouched" \
    test "$(sk inspect --format '{{.Digest}}' "docker://$disc/standard:1.2.3")" = "$src_digest"

if ((${#failed[@]})); then
    printf '\n%d failed:\n' "${#failed[@]}"; printf '  %s\n' "${failed[@]}"; exit 1
fi
echo "all release checks passed"
