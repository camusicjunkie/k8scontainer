# Release Owner guide

For the Release Owner (and the named backup). Terms are those of `GLOSSARY.md`. Anyone may ask for a Release; only you decide when one is cut. A Release is one versioned build of the Standard Image, carried across the air gap as an image archive plus its checksum. Anything marked **Unverified** is covered by `docs/e2e-checklist.md`.

## One-time setup (Connected Side)

**GitLab CI variables** (Settings, CI/CD, Variables):

| Variable | Value |
|---|---|
| `HARBOR_IMAGE` | the Connected Registry repository without a tag, e.g. `harbor.example/devcontainer/standard` |
| `HARBOR_USER` | a Harbor robot account with push on that project |
| `HARBOR_PASSWORD` | its secret, masked and protected |

**kubectl-vsphere** (optional, needed for `klogin`). It ships only from a Supervisor, so the build fetches it from one when you set two more variables. Leave both unset and the image has no plugin; its MANIFEST says `kubectl-vsphere absent`.

| Variable | Value |
|---|---|
| `SUPERVISOR_HOST` | a Supervisor control-plane address the runner can reach, e.g. `10.0.0.10` |
| `VSPHERE_PLUGIN_SHA256` | the SHA-256 of `https://<SUPERVISOR_HOST>/wcp/plugin/linux-amd64/vsphere-plugin.zip` (`curl -fsSLk <url> \| sha256sum`); the build refuses any other file |

The zip is fetched without TLS verification (Supervisors usually carry their own certificate) and trusted by that checksum, so update `VSPHERE_PLUGIN_SHA256` after each Supervisor upgrade: until then the build fails, by design. A hand build passes the same two values with `--build-arg`.

**Protect the Release tag pattern** (`v*` and `[0-9]*`, matching `vX.Y.Z` and `X.Y.Z`) so only you can create it. Pushing a Release tag is the gate: nothing reaches a Registry until you do.

**Runner needs** (from `.gitlab-ci.yml`): the job container must be allowed user namespaces (seccomp must not block `unshare`) and be given a `/dev/fuse` device, because buildah overlays the build context for `RUN --mount=type=bind`. It needs neither `--privileged` nor a Docker daemon. On a GitLab docker-executor runner that is `devices = ["/dev/fuse"]` and `security_opt = ["seccomp=unconfined", "apparmor=unconfined"]` under `[runners.docker]`; under Docker's default seccomp rules buildah fails with `unshare(CLONE_NEWUSER): Operation not permitted`.

**`candidate` images accumulate.** Every pipeline pushes `candidate:<commit sha>` to the project's Container Registry. Add a registry cleanup policy for that repository or it grows without bound.

**DHI login.** The DHI base's registry (`dhi.io`) needs a login: set `DHI_USER` and `DHI_PASSWORD` (masked, and raw if the token contains `$`) to a Docker account entitled to the base, and the build logs in before it pulls. Without them the build fails at the first DHI stage with `authentication required`.

**Checked on a local GitLab CE with a docker-executor runner set up as above:** a branch push runs `build`, `checks` and `selftest`; the self-test passes all its checks under rootless isolation with `--network none` (chroot isolation leaves the network up); a `v0.0.1` tag also runs `publish`, and the Harbor tag carries the same digest as the `candidate` that passed. The build also needs Internet and Marketplace access (it fetches the VS Code server and extensions), which is why it runs only on the Connected Side.

**Unverified:** the real runner, the real Container Registry and the real Harbor with its robot credentials.

## Before each Release

- **Refresh the DHI base digest.** `image/Dockerfile` pins the base (`DHI_BASE`) by digest. Its apt repository keeps moving, so a stale digest can make package installs fail. Get the current digest, for example `docker buildx imagetools inspect dhi.io/debian-base:trixie-dev`, and update the `ARG DHI_BASE=` line. Do this every Release.
- **Check the other pins.** The VS Code commit and its checksums are in `image/packages/vscode.env`, extensions in `image/packages/vscode-extensions.txt`; both move only with a Release, and the Workstation pack must match them (below).
- **Optional local check** (Docker needed): `bash tests/image.sh` builds the image and runs the self-test with no network. The pipeline runs the same self-test, `devc-selftest`, with no network, as a gate.

## Cutting a Release

1. **Tag.** Push a tag `X.Y.Z` (or `vX.Y.Z`) on the commit to release. The pipeline builds the image, runs `devc-selftest` in that exact image, and only if it passes publishes the same image to `$HARBOR_IMAGE:<tag>`. A failing self-test, an untagged push and a non-Release tag never publish. Use one tag spelling consistently: the Harbor tag is the Git tag as pushed, and the image automation reads it as a version.
2. **Cut.** On a machine that can reach the Connected Harbor and has `skopeo` and `sha256sum`:

   ```bash
   release/cut.sh harbor.example/devcontainer/standard:1.2.3 1.2.3 out/
   ```

   Set `SRC_CREDS=user:password` if Harbor needs it. It writes:

   - `out/devcontainer-1.2.3.oci.tar`, the image archive
   - `out/devcontainer-1.2.3.oci.tar.sha256`, its checksum (`sha256sum -c` format)
   - `out/review-1.2.3/SUMMARY.md`, the Review Packet

   It refuses a version that is not `X.Y.Z`, refuses an existing Release in that folder, and fails rather than let the image's digest change. The cut is run by hand; it is not part of CI.
3. **Review.** The Review Packet gives the version, archive name, SHA-256, image digest, source and image labels (revision and version). **It does not yet contain a vulnerability scan (Trivy), an SBOM or a "changes since the last Release" section**; the old repository had these. Until they are added, produce whatever your transfer process needs from the image digest by other means and attach it.
4. **Assemble the Workstation pack.** No script builds it, so you assemble it by hand, from files for the VS Code commit pinned in `image/packages/vscode.env`. One folder, with exactly this layout:

   | File | What it is |
   |---|---|
   | `install.ps1`, `settings.json` | copied from `workstation/` |
   | `vscode.env` | a copy of `image/packages/vscode.env` |
   | `release.json` | `version` (the Release), `vscode` with `version`, `commit` and `zip` (file name), and `extensions`: exactly one entry with `id` `ms-vscode-remote.remote-ssh`, `version` and `file` (the VSIX file name) |
   | the portable VS Code zip | the Windows x64 archive for that commit; its SHA-256 must equal `VSCODE_WIN_SHA256` in `vscode.env` |
   | the Remote-SSH VSIX | the one extension the installer installs; its version is not pinned anywhere in this repository, so choose one that works with that VS Code and record it in `release.json` |
   | `SHA256SUMS` | `sha256sum` format (`<hash>  <relative path>`), covering every file above except `install.ps1` and `SHA256SUMS` itself |

   The installer refuses the pack if any covered file is missing or mismatched, if a file it uses is not covered, if `release.json`'s VS Code commit or version differs from `vscode.env`, if the zip is not the pinned one, or if the Release carries any extension other than Remote-SSH. Run `install.ps1` once on a test Workstation before carrying the pack. **Unverified:** a real portable VS Code download and `code.cmd`, installing the real VSIX offline, and the real Remote-SSH version check.
5. **Carry across.** Move the archive, its `.sha256` file, the Workstation pack and the Review Packet through your transfer process. Only the archive and checksum are needed to import.

## Importing on the Disconnected Side

On a machine that can reach the Disconnected Harbor and has `skopeo`:

```bash
release/import.sh devcontainer-1.2.3.oci.tar harbor.example/devcontainer/standard:1.2.3
```

Set `DEST_CREDS=user:password` if the Registry needs it. In order, it:

1. checks the checksum and refuses a mismatch before touching the Registry,
2. refuses if the destination tag already exists (a version is never overwritten),
3. copies with the digest preserved, and
4. confirms the Registry's digest equals the archive's, which is the digest the Connected Side built.

The existence check and the push are not atomic, so do not run two imports of one version at once. **Unverified:** both scripts were tested only against local HTTP registries, not real Harbor (authentication, TLS, robot accounts, `SRC_CREDS` and `DEST_CREDS`). The Release crosses a gate only when `docs/e2e-checklist.md` passes.

## What happens next on the Management Cluster

The image automation on each side's Management Cluster picks the new tag up and commits it to the Roster on a push branch (`image-updates`, as the Gitops repository's own automation does). Merging that branch's merge request is what rolls the Release out; nothing restarts. Each admin restarts their own Pod when ready (see the admin guide).

- `manifests/devcontainer/image-automation.yaml` ships an ImageRepository (scans the Registry every 5 minutes) and an ImagePolicy (`semver: ">=0.1.0"`, which never selects a pre-release tag). The Roster carries one marked `image:` line, `# {"$imagepolicy": "devcontainer:devcontainer-standard"}`, rendered into every admin's Pod template.
- **The ImageUpdateAutomation is not in this repository**, because it holds Git push credentials. The Gitops repository's existing one does not cover it: that one lives in `flux-system` and updates the Gitops repository's own `./apps`. Add one in the `devcontainer` namespace (an automation applies only the ImagePolicies in its own namespace) with `update.path: ./manifests/devcontainer` and `push.branch: image-updates`. Give it its own GitRepository in that namespace with a `write_repository` token, and keep the GitRepository Flux syncs this repository from read-only. `tests/kind/flux.yaml` is a working example; the namespace exists only after the first sync, so apply the automation from a Kustomization that `dependsOn` the one syncing this repository. If the Registry needs a pull credential, add `secretRef` to the ImageRepository (a Secret supplied outside Git).
- **Harbor's CA for the scanner.** A Harbor whose certificate comes from a private CA (a Supervisor service's, for one) is trusted by the cluster's nodes, but not by the image-reflector-controller, which runs in a Pod with its own CA bundle. Patch `certSecretRef: {name: harbor-ca}` onto the ImageRepository from the Kustomization that syncs this repository, and have a `harbor-ca` Secret (key `ca.crt`) in the `devcontainer` namespace; the Gitops repository's Kyverno policy that copies `harbor-pull` into each namespace can copy it too.
- The placeholder host `harbor.example` in the ImageRepository and the Roster must be replaced with each network's Registry. The Gitops repository's Kyverno policy rewrites every Pod image not already on `${HARBOR_REGISTRY}` to `${HARBOR_REGISTRY}/${HARBOR_PROJECT}/devcontainer/<name:tag>`, so publish to that path (`HARBOR_IMAGE`) and point the ImageRepository at it; the automation then writes that same path into the Roster and the rewrite leaves it alone.

**Checked on a kind cluster** (`tests/kind/up.sh`, then `tests/cluster-live.sh`) with Flux's image controllers and the Gitops repository's Kyverno policies, pulling the image the local GitLab CI built: the Pod runs under Pod Security `restricted` and answers SSH with the Roster's key; a restart keeps the State Directory and host key; a new tag is committed to the Roster on the push branch, and once merged reaches the StatefulSet but the Pod only on restart; removing the admin removes the Pod and keeps the volume, and adding them back finds their state. **Unverified:** Istio programming the Gateway, and real Harbor.

## Rolling back

Narrow the ImagePolicy `range` in `manifests/devcontainer/image-automation.yaml` to the exact earlier version, for example `"0.1.0"`, and merge. The automation then rewrites the Roster's image to it on the push branch; merge that too, and admins pick it up on their next Pod restart. Restoring `">=0.1.0"` resumes following Releases. Editing the Roster's image line alone does not stick: the automation moves it forward again.

## Known limits

- Certificate authority changes in Site Config reach a Pod only when its admin restarts it.
- No script builds the Workstation pack, and the Review Packet is incomplete (see above).
- `kubectl-vsphere` is in the image only when the build sets `SUPERVISOR_HOST` (above); without it `klogin` cannot complete a login.
- Removing a Roster entry leaves that admin's volume behind (see the admin guide).
