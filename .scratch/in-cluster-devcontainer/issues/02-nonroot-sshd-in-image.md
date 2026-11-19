# 02: Non-root `sshd` in the image

**What to build:** The image starts a non-root `sshd` that an admin can connect to with a key and Remote-SSH, with the forwarded smartcard agent usable inside the session.

**Blocked by:** 01

**Status:** ready-for-agent

- [ ] `sshd` starts as the image's non-root user and listens on a high port
- [ ] Only public keys from a mounted key list are accepted; passwords and other users are refused
- [ ] Agent forwarding and TCP forwarding work in a session
- [ ] The host key is read from, and created once on first start at, a mounted path
- [ ] The self-test covers key-only login and forwarding, run with no network
