# 06: Reach the Pod over the Gateway

**What to build:** An admin Remote-SSHes from their Workstation to their Pod through the shared Gateway IP and their own port, authenticating with their smartcard key.

**Blocked by:** 05

**Status:** ready-for-agent

- [ ] The Gateway has a TCP listener and route to the Pod on the admin's port
- [ ] Remote-SSH connects with the smartcard key and opens a shell in the Pod
- [ ] The host key is the same after a Pod restart, so no host-key warning appears
- [ ] The Pod is reachable from the Workstation without any Kubernetes API access
