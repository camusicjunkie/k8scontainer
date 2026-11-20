#!/usr/bin/env bash
# cut.sh: cuts a Release on the Connected Side from an image already published
# to the Connected Harbor by the pipeline.
#
#   release/cut.sh SOURCE_IMAGE VERSION OUTDIR
#
#   SOURCE_IMAGE  host/repo:tag of the tagged image, e.g. harbor.example/devcontainer/standard:1.2.3
#   VERSION       X.Y.Z (a leading v is allowed)
#   OUTDIR        where the Release files and the Review Packet are written
#
# Writes in OUTDIR:
#   devcontainer-VERSION.oci.tar         the image archive (OCI layout)
#   devcontainer-VERSION.oci.tar.sha256  its checksum, in `sha256sum -c` format
#   review-VERSION/SUMMARY.md            the Review Packet
#
# The archive and checksum are the Release; the Review Packet goes to the
# transfer process and is never needed to import. The copy uses skopeo's
# --preserve-digests, so it fails rather than change the image's digest.
#
# Environment: SRC_CREDS (user:password for the source, optional),
# DEVC_INSECURE=1 (skip TLS verification; for local test registries only).
set -euo pipefail

die() { echo "cut.sh: $*" >&2; exit 1; }
(($# == 3)) || die "usage: cut.sh SOURCE_IMAGE VERSION OUTDIR"
src=$1 version=$2 out=$3
[[ $version =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version must be X.Y.Z, got '$version'"

archive=$out/devcontainer-$version.oci.tar
review=$out/review-$version
[[ ! -e $archive && ! -e $review ]] || die "Release $version already exists in $out; a version is never reused"

opts=() copts=()
[[ -z ${DEVC_INSECURE:-} ]] || { opts+=(--tls-verify=false); copts+=(--src-tls-verify=false); }
[[ -z ${SRC_CREDS:-} ]] || { opts+=(--creds "$SRC_CREDS"); copts+=(--src-creds "$SRC_CREDS"); }

mkdir -p "$out"
partial=$archive.part
trap 'rm -f "$partial"' EXIT

echo "==> archiving $src"
skopeo copy --all --preserve-digests "${copts[@]}" \
    "docker://$src" "oci-archive:$partial:$version"

src_digest=$(skopeo inspect "${opts[@]}" --format '{{.Digest}}' "docker://$src")
archive_digest=$(skopeo inspect --format '{{.Digest}}' "oci-archive:$partial:$version")
[[ $src_digest == "$archive_digest" ]] ||
    die "digest changed in the archive ($src_digest became $archive_digest)"

mv "$partial" "$archive"
(cd "$out" && sha256sum "devcontainer-$version.oci.tar" >"devcontainer-$version.oci.tar.sha256")
sum=$(cut -d' ' -f1 "$archive.sha256")

labels=$(skopeo inspect --config "${opts[@]}" "docker://$src" |
    sed -n 's/.*"org.opencontainers.image.\(revision\|version\)": *"\([^"]*\)".*/- \1: \2/p')

mkdir -p "$review"
{
    echo "# Review Packet: Release $version"
    echo
    echo "| | |"
    echo "|---|---|"
    echo "| Version | $version |"
    echo "| Archive | \`devcontainer-$version.oci.tar\` |"
    echo "| SHA-256 | \`$sum\` |"
    echo "| Image digest | \`$src_digest\` |"
    echo "| Source | \`$src\` |"
    echo "| Cut at | $(date -u +%Y-%m-%dT%H:%M:%SZ) |"
    echo
    echo "## Check the files are intact"
    echo
    echo "    sha256sum -c devcontainer-$version.oci.tar.sha256"
    echo
    echo "release/import.sh runs the same check before it loads anything, and the"
    echo "image it loads has the digest above."
    if [[ -n $labels ]]; then
        echo
        echo "## Image labels"
        echo
        echo "$labels"
    fi
} >"$review/SUMMARY.md"

echo "==> Release $version: $archive"
echo "    sha256 $sum"
echo "    digest $src_digest"
