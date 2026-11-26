# Admin guide

For an admin who has a Devcontainer Pod, and for whoever keeps the Roster. Terms are those of `GLOSSARY.md`. Why it is built this way: `docs/adr/0001-admins-reach-their-pod-over-sshd.md` and `docs/adr/0002-one-pod-per-admin-with-no-runtime-root.md`.

Anything marked **Unverified** was built and tested only in part (see the ticket Answers under `.scratch/in-cluster-devcontainer/issues/`). The manual end-to-end checklist, `docs/e2e-checklist.md`, is where those items get proved on the Disconnected Side.

## What you have

Your own Devcontainer Pod on the Management Cluster, running the Standard Image. It keeps running between sessions. Your State Directory, one persistent volume (20Gi by default), holds everything of yours that outlives the Pod. The volume is mounted only at these paths in the Pod:

| Path in the Pod | Holds |
|---|---|
| `~/workspace` | your workspace |
| `~/.kube` | cluster logins |
| `~/.secrets` | your Secrets File |
| `~/.devc/personal` | your Personal Config |
| `~/.local` | tools you install yourself |
| `/var/lib/devc/hostkeys` | the Pod's `sshd` host key |

The rest of the Pod's user area comes from the Standard Image, so each Release refreshes the baked-in VS Code server, extensions and dotfiles. Anything you write outside the paths above is gone when the Pod restarts.

You reach the Pod with Remote-SSH from your Workstation, through the shared Gateway IP and your own port. You need no Kubernetes API access to work in it, and the Pod holds no Kubernetes API credentials.

## First connection

You need from the Release Owner: the Release's Workstation pack (a folder holding `install.ps1`). You need from whoever keeps the Roster: the Gateway host and your port, and your entry merged into the Roster.

1. **Get on the Roster.** Your entry in `manifests/devcontainer/roster.yaml` has a `name`, a `port`, your smartcard's PIV Authentication public key (`publicKey`) and optional `resources`. Merging it provisions your Pod, volume, key list, Service and Gateway route. The key must be RSA (see Secrets File below).
2. **Run the installer** from the pack, in Windows PowerShell 5.1 or PowerShell 7, with no network:

   ```powershell
   .\install.ps1 -GatewayHost <gateway host> -Port <your port>
   ```

   It checks every file against the pack's `SHA256SUMS` before writing anything, refuses a VS Code commit that differs from the one baked into the image, installs only the Remote-SSH extension, writes the offline VS Code settings and adds a `Host devcontainer` block (the Gateway host, your port, user `dev`, `ForwardAgent yes`) to `~\.ssh\config`. Rerunning it is safe. Use `-HostAlias` if your SSH config already has its own `Host devcontainer`, and `-From <previous install folder>` to carry your VS Code user data forward from an earlier Release. You do not need `kubectl`, the vSphere plugin or the Dev Containers extension.
3. **Start the VS Code it printed** (`Code.exe` in the install folder), then Remote-SSH: Connect to Host, and pick `devcontainer`. Use your smartcard when asked. Nothing is downloaded: the VS Code server and extensions are already in the Standard Image.

The Pod's `sshd` accepts only the public keys from the Roster and no passwords. Its host key lives on your volume, so you should see no host-key warning after a restart.

**Unverified:** a real Remote-SSH session through a real Gateway, the version-match check against the real portable VS Code, and a real smartcard in the Windows agent. See e2e sections 3 and 4.

## Personal Config

Personal Config is yours alone and never holds secrets. It lives on your volume at `~/.devc/personal`:

- `personal.env`: `NAME=value` lines, loaded into every login shell (including `ssh host command`) after Site Config, so yours override the network's. It is where `DEVC_UNLOCK_KEY` and your default `klogin` targets (`KLOGIN_SERVER`, `KLOGIN_NAMESPACE`, `KLOGIN_CLUSTER`) go.
- `bashrc`: your prompt and aliases, sourced by every interactive shell. Put them here, not in `~/.bashrc`: `~/.bashrc` is not on your volume, so edits there are lost on restart. Checked in e2e section 6.

Site Config is different: it belongs to the network, is a read-only ConfigMap rendered by Flux, and you cannot change it. It supplies the network's certificate authorities and the Supervisor addresses `klogin` uses.

## The Secrets File

Your Secrets File is an `ansible-vault` file at `~/.secrets/vault`, unlocked by a signature from your smartcard made through the forwarded agent. It is created once:

1. Find your card's PIV Authentication key fingerprint with `ssh-add -l` in a VS Code terminal.
2. Put it in `~/.devc/personal/personal.env` as `DEVC_UNLOCK_KEY=SHA256:...`, then open a new login shell.
3. `secrets init`. It refuses an existing file, a key that is not in the agent, a key that is not RSA, and a key whose signatures of the challenge differ between calls.
4. `secrets edit` to fill in `VSPHERE_USER`, `VSPHERE_PASSWORD`, `GITLAB_TOKEN` and any others (`secrets view` prints it).
5. `with-secrets -k NAME command` runs one command with those values in its environment and nowhere else.

These only work in a shell that has the forwarded agent, which means a VS Code terminal over Remote-SSH. Without the agent they stop with a message saying so. The key must be RSA and the card's PIV Authentication key: only RSA signatures repeat exactly, and the Digital Signature key asks for the PIN on every unlock. **Unverified on real cards**: only a software RSA key was tested. If a card's agent produces differing signatures, `secrets init` refuses it. A new card means removing `~/.secrets/vault` and running `secrets init` again.

Note: some messages from `secrets` mention "Rebuild Container" and `docker exec`, wording left over from the old Docker Host design. In a Devcontainer Pod it means opening a new login shell, and, if that is not enough, restarting your Pod.

## `klogin`

`klogin` logs you in to a Supervisor or Guest Cluster with `kubectl vsphere login`, taking the vCenter user and password from the Secrets File.

```bash
klogin                          # your personal.env defaults, or the Supervisor only
klogin <vSphere Namespace>      # the Supervisor, with that namespace's context
klogin <vSphere Namespace> <Guest Cluster>
```

The Supervisor is `KLOGIN_SERVER` from `personal.env`, or the single entry in Site Config's `KLOGIN_SERVERS`; with several entries you must choose one. Tab completion offers Site Config's `KLOGIN_NAMESPACES` and `KLOGIN_CLUSTERS`. Logins land in `~/.kube`, which is on your volume.

**Known gap:** `kubectl-vsphere` is in the Standard Image only when the Release Owner builds it with a Supervisor's plugin zip (`SUPERVISOR_HOST`; `/etc/devcontainer/release` says `kubectl-vsphere absent` otherwise). Without it, `klogin` runs only as far as finding it missing. Tests used a stub. **Unverified:** a real Supervisor or Guest Cluster.

## Installing a tool into your user area

There is no root in the Pod and no `sudo`. To get a tool you need before the Release Owner adds it to the image, put it in `~/.local/bin`, which is on your volume and on `PATH` in new shells:

```bash
mkdir -p ~/.local/bin
cp ./mytool ~/.local/bin/ && chmod +x ~/.local/bin/mytool
```

It survives restarts. Non-interactive commands (`ssh host command`) do not read profiles, so `~/.local/bin` is on `PATH` only in shells. Tell the Release Owner what you installed so it can be considered for the next Release.

## Restarting for a new Release

A new Release changes the Pod spec but never restarts a running Pod. You restart on your own schedule:

1. Delete your Pod; the StatefulSet recreates it from the new spec and reuses your volume:

   ```bash
   kubectl -n devcontainer delete pod devc-<your name>-0
   ```

   This needs permission to delete Pods in the Devcontainer Namespace on the Management Cluster. Nothing in this repository grants it and the Pod itself has no Kubernetes API credentials, so run it from your own cluster login or ask someone who has access.
2. Reconnect with Remote-SSH. Your workspace, cluster logins, Secrets File, Personal Config and installed tools are as you left them.
3. If the Release carries a new VS Code commit, run the new pack's `install.ps1` first (use `-From` to keep your settings), because Remote-SSH refuses a mismatch between the Workstation's VS Code and the Pod's server.

The Standard Image is the same on both networks; each Management Cluster pulls it from the Registry on its own side. **Unverified:** restart behaviour on a real cluster (the new image runs and the volume is intact). See e2e section 7.

If a Release turns out bad, the Release Owner rolls back (see the Release Owner guide); you pick the rollback up by restarting your Pod the same way.

## Platform notes (Roster and manifests)

For whoever merges Roster entries and runs the Management Cluster.

- **Adding an admin:** merge a Roster entry with a unique `name` (a DNS label) and a unique `port`. The ResourceSet generates a listener on the shared Gateway, a key list, two Services, a TCPRoute and the StatefulSet with its volume. Nothing per-admin is hand-written. The design assumes roughly 20 admins or fewer behind one Gateway IP.
- **One bad entry breaks all of them.** The Roster is a single input set, so a duplicate name or port or a malformed key stops the ResourceSet from rendering for every admin. Keep at least one admin on it: an empty Roster removes the shared Gateway.
- **Resources:** defaults are requests 250m CPU and 512Mi memory, limits 2 CPU and 4Gi. An entry may override any of `requests.cpu`, `requests.memory`, `limits.cpu`, `limits.memory`.
- **Removing an admin:** removing the entry prunes their Pod, key list, Services, route and Gateway listener, ending their access with the merge. **It leaves their volume (PVC `state-devc-<name>-0`) behind**, on purpose, so a mistaken merge does not destroy it. Delete the PVC by hand when you are sure.
- **Site Config:** `manifests/devcontainer/site-config.yaml` holds no values of its own: its `site.env` and `site-ca.crt` are runtime facts (`DEVCONTAINER_SITE_ENV_B64`, `DEVCONTAINER_SITE_CA_B64`) that the Gitops repository's bootstrap writes from its `devcontainer_site_env` and `devcontainer_site_ca` variables (KLOGIN settings, the AI gateway, site CAs), so nothing network-specific is committed here. `tests/site` holds the values the tests and kind use.
- **Certificate authority changes apply on Pod restart.** CAs are mounted as single files and the trust store is rebuilt when the Pod starts, so a Site Config change reaches an admin only when they restart their Pod.
- **StorageClass and volume size are set once.** Every volume uses the Roster's `storageClass`, beside `imageTag`; leave it out and each claim takes the cluster's default class. Set it before the first admin: a StatefulSet's claim template cannot change, and because the Roster is one input set, a change stops the ResourceSet applying for every admin, not just new ones. The same holds for the 20Gi size in the ResourceSet. Changing either later means deleting each StatefulSet with `--cascade=orphan` (the volumes stay) for the ResourceSet to recreate.
- **Namespace:** the Devcontainer Namespace enforces Pod Security `restricted`. It joins no mesh: the Istio gateway reaches the Pods without one. Pods run as user 1000, all capabilities dropped, no privilege escalation, the runtime-default seccomp setting, no mounted ServiceAccount token.
- **ResourceSet identity:** it has no `serviceAccountName` yet, so it applies as the Flux Operator. Set one with narrow RBAC once the Gitops repository defines it.
- **NetworkPolicy:** `manifests/devcontainer/networkpolicy.yaml` admits SSH to each Pod only from the shared Gateway's Pod, so one admin's Pod can't reach another's `sshd`. Egress goes to cluster DNS and anywhere outside the cluster's Pod network, never to other Pods, so TCP forwarding over an admin's session is not a way into the Management Cluster's workloads. The Pod CIDR is a runtime fact, `DEVCONTAINER_POD_CIDR` (VKS's default `192.168.0.0/16` when unset; see the README's "Runtime facts"). If an admin needs to reach something inside the cluster, that is a change to this policy, not a workaround.
- **Gateway address:** the Roster's `gatewayAddress` comes from the runtime fact `DEVCONTAINER_GATEWAY_ADDRESS`; set it to pin the Gateway's LoadBalancer IP (`none`, the default, leaves it to the load balancer), and give it a DNS name; Workstations should use the name in `-GatewayHost`. Without a pinned address, the Gateway can come back on a new IP if it is recreated, for example when the Roster briefly has no admins (an empty Roster renders no Gateway), and every Workstation's SSH config would need rewriting.
- **Unverified:** that the Flux Operator accepts the ResourceSet and prunes on removal, the Gateway's external address on the real load balancer (kind checks the listener, route and gateway Pod through the gateway's Service), the NetworkPolicy, and the StorageClass. Istio must be 1.31 or later (see the README). See e2e sections 2 and 8.
