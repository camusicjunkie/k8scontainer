# 11: Release across the air gap

**What to build:** A Release is cut as an image archive plus a checksum with a Review Packet, carried to the Disconnected Side and loaded into its Harbor, so the same Standard Image runs on both networks.

**Blocked by:** 04

**Status:** resolved

- [x] The Release Owner can produce the archive, checksum and Review Packet from a tagged image
- [x] The import into the Disconnected Harbor checks the checksum first and refuses a mismatch
- [x] The imported image has the same digest as the one built on the Connected Side
- [x] The import refuses to overwrite an existing version

## Answer

Added `release/cut.sh` (Connected Side) and `release/import.sh` (Disconnected Side), tested by `tests/release.sh`.

- `cut.sh SOURCE_IMAGE VERSION OUTDIR` copies the tagged Harbor image to `devcontainer-VERSION.oci.tar` with `skopeo copy --all --preserve-digests`, writes `devcontainer-VERSION.oci.tar.sha256` (`sha256sum -c` format) and the Review Packet `review-VERSION/SUMMARY.md` (version, checksum, image digest, source, how to verify). It refuses a non-X.Y.Z version and an existing Release.
- `import.sh ARCHIVE DEST_IMAGE` checks the checksum first and refuses a mismatch before touching the Registry, refuses if the destination tag already exists, copies with `--preserve-digests` and confirms the Registry digest equals the archive's.
- `tests/release.sh` uses two throwaway `registry:2` containers and the pinned skopeo image (v1.25.1); all 15 checks pass.

Not done or not verified:
- The Review Packet has no vulnerability scan or SBOM, and no "what changed since the previous Release" section (the old repo had both). Say if you want them.
- Checked only against local HTTP registries, not real Harbor (auth, TLS, robot accounts). `SRC_CREDS` and `DEST_CREDS` are untested.
- The existence check and the push are not atomic, so two simultaneous imports of one version could race.
- Digest preservation relies on the pipeline's buildah image being OCI format (buildah's default); `--preserve-digests` makes cut fail loudly otherwise. The test source image is converted to OCI with skopeo, not built by the real pipeline.
- Not wired into CI; the Release Owner runs cut by hand.
