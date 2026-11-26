# 02: Non-root `sshd` in the image

**What to build:** The image starts a non-root `sshd` that an admin can connect to with a key and Remote-SSH, with the forwarded smartcard agent usable inside the session.

**Blocked by:** 01

**Status:** resolved

- [x] `sshd` starts as the image's non-root user and listens on a high port
- [x] Only public keys from a mounted key list are accepted; passwords and other users are refused
- [x] Agent forwarding and TCP forwarding work in a session
- [x] The host key is read from, and created once on first start at, a mounted path
- [x] The self-test covers key-only login and forwarding, run with no network

## Answer

The image ships `openssh-server` and `devc-sshd`, the new default command. It runs sshd in the foreground as `dev` on port 2222 (`DEVC_SSHD_PORT`). It accepts only public keys listed in `/etc/devc/authorized_keys` (`DEVC_AUTHORIZED_KEYS`) and only for the image's own user. Passwords, keyboard-interactive, root and every other user are refused. Agent and TCP forwarding are on. The ed25519 host key is read from `/var/lib/devc/hostkeys` (`DEVC_HOSTKEY_DIR`, an empty directory owned by `dev` in the image) and created there on first start, so it survives a restart when that path is a volume.

The self-test has a new drop-in, `selftest.d/20-sshd.sh`. It starts a throwaway `devc-sshd` on loopback with its own keys and checks listed-key login, an unlisted key, other users, no password login, agent forwarding, TCP forwarding and host-key creation. `tests/image.sh` also starts the real image with `--network none`, mounts a key list, and logs in from inside the container. It checks the process runs as non-root, that the host key is stable across a restart on a volume, and the same refusals and forwarding.

Verified on Docker Desktop: the build succeeds, the self-test passes 99 of 99 offline, and every case in `tests/image.sh` passes.

Not verified: a real client from outside the container, such as Remote-SSH through the Gateway, and a smartcard-backed agent. Only a software ed25519 key and a local `ssh-agent` were used. `StrictModes` is off so a ConfigMap or Secret mount with symlinked paths works. Pod Security `restricted` behaviour is covered by the cluster tickets.
