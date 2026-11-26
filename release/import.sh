#!/usr/bin/env bash
# import.sh: loads a Release into the Disconnected Harbor with skopeo.
#
#   release/import.sh ARCHIVE DEST_IMAGE
#
#   ARCHIVE     devcontainer-VERSION.oci.tar, with its .sha256 file beside it
#   DEST_IMAGE  host/repo:tag to create, e.g. harbor.example/devcontainer/standard:1.2.3
#
# In order, it: checks the checksum and refuses a mismatch; refuses if DEST_IMAGE
# already exists (a version is never overwritten); copies with --preserve-digests
# so the image keeps the digest it had on the Connected Side; and confirms the
# digest in the Registry equals the archive's.
#
# Environment: DEST_CREDS (user:password for the Registry, optional),
# DEVC_INSECURE=1 (skip TLS verification; for local test registries only).
set -euo pipefail

die() { echo "import.sh: $*" >&2; exit 1; }
(($# == 2)) || die "usage: import.sh ARCHIVE DEST_IMAGE"
archive=$1 dest=$2
[[ -f $archive ]] || die "no archive at $archive"
[[ -f $archive.sha256 ]] || die "no checksum file at $archive.sha256"

echo "==> checking checksum"
(cd "$(dirname "$archive")" && sha256sum -c --status "$(basename "$archive").sha256") ||
    die "checksum mismatch: $archive is not the file that was cut; nothing was imported"

opts=()
[[ -z ${DEVC_INSECURE:-} ]] || opts+=(--tls-verify=false)
[[ -z ${DEST_CREDS:-} ]] || opts+=(--creds "$DEST_CREDS")

# Only "not found" means the version is free; any other failure stops the import.
if err=$(skopeo inspect --no-tags "${opts[@]}" "docker://$dest" 2>&1 >/dev/null); then
    die "$dest already exists; a version is never overwritten"
elif ! grep -qiE 'manifest unknown|name unknown|not found|404' <<<"$err"; then
    die "could not tell whether $dest exists: $err"
fi

want=$(skopeo inspect --format '{{.Digest}}' "oci-archive:$archive")

echo "==> importing into $dest"
dopts=()
[[ -z ${DEVC_INSECURE:-} ]] || dopts+=(--dest-tls-verify=false)
[[ -z ${DEST_CREDS:-} ]] || dopts+=(--dest-creds "$DEST_CREDS")
skopeo copy --all --preserve-digests "${dopts[@]}" "oci-archive:$archive" "docker://$dest"

got=$(skopeo inspect "${opts[@]}" --format '{{.Digest}}' "docker://$dest")
[[ $got == "$want" ]] || die "imported digest $got differs from the archive's $want"
echo "==> imported $dest"
echo "    digest $got"
