# 08: Secrets File and `klogin` in the Pod

**What to build:** An admin creates and unlocks their Secrets File inside the Pod using the forwarded smartcard agent, then logs in to a Supervisor or Guest Cluster with `klogin`.

**Blocked by:** 06

**Status:** resolved

- [x] Creating the Secrets File succeeds only with an RSA PIV Authentication key whose signatures repeat
- [x] The Secrets File unlocks in a Remote-SSH terminal with the agent forwarded and refuses without it
- [x] `klogin` logs in to a Supervisor and a Guest Cluster using the Site Config targets, and the logins survive a Pod restart
- [x] A clear message appears when the agent is not forwarded

## Answer

The Secrets File helpers (`secrets`, `with-secrets`, `devc-vault-pass`), `klogin` and its completion were already in the image from ticket 01 and needed no port. The gap was that nothing loaded Site Config or `personal.env` into shells in the Pod (the old design used compose `env_file`), so `KLOGIN_SERVERS` and `DEVC_UNLOCK_KEY` were never set. Added `image/rootfs/etc/profile.d/20-config-env.sh`, which exports `/etc/devcontainer/site/site.env` and then `~/.devc/personal/personal.env` in every login shell, including `ssh host command`.

`tests/secrets-klogin.sh` runs the image sshd with the Pod mounts (state volumes at `~/.secrets`, `~/.kube`, `~/.devc/personal`, Site Config read-only) and drives the helpers over ssh from a client with a local software-key ssh-agent forwarded with `-A`. All cases pass against a locally built image: init refuses an ed25519 key, a key missing from the agent, non-repeating signatures (RSA with a stubbed signing `ssh-keygen`) and an existing file; init succeeds with RSA; unlock works with the agent and refuses without it, with a clear message; `klogin` Supervisor and Guest Cluster calls use the Site Config server and flags and refuse without the agent; the login and the Secrets File survive recreating the container on the same volumes.

Not verified: a real smartcard and PIV Authentication key, a real Supervisor or Guest Cluster, `kubectl-vsphere` itself (the test uses a stub kubectl; the plugin is still absent from the image), and a real Pod on a cluster (a Docker container with the same mounts stands in).
