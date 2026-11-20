# 06: Reach the Pod over the Gateway

**What to build:** An admin Remote-SSHes from their Workstation to their Pod through the shared Gateway IP and their own port, authenticating with their smartcard key.

**Blocked by:** 05

**Status:** resolved

- [ ] The Gateway has a TCP listener and route to the Pod on the admin's port
- [ ] Remote-SSH connects with the smartcard key and opens a shell in the Pod
- [ ] The host key is the same after a Pod restart, so no host-key warning appears
- [ ] The Pod is reachable from the Workstation without any Kubernetes API access

## Answer

Added to `manifests/devcontainer/`: a Gateway (`gatewayClassName: istio`, one TCP listener `ssh-admin` on port 2201, routes from its own namespace only), a `TCPRoute` (`gateway.networking.k8s.io/v1alpha2`) from that listener to a new ClusterIP Service `admin-ssh` (2222; the headless `admin` Service stays for the StatefulSet), and ConfigMap `admin-authorized-keys` mounted read-only as the single file `/etc/devc/authorized_keys`. The key in it is a placeholder RSA public key (private half discarded); the admin, key and port are hard-coded until the Roster (ticket 07). The Pod still has `automountServiceAccountToken: false`, so it holds no Kubernetes API credentials.

API choice, checked against the flux-schema-catalog (gateway-api v1.7.0): the catalog serves TCPRoute at both `v1` and `v1alpha2`. I used `v1alpha2`, the version Istio's controller has always read and that older Gateway API CRD installs serve; Gateway is `v1`. Confirm which version the Management Cluster's CRDs serve; `v1` is possible on 1.7+.

`tests/cluster.sh` / `tests/cluster_policy.py` now also check, all passing: kubeconform validates the Gateway and TCPRoute (CRDs catalog) as well as the Kubernetes kinds; the listener/route/Service/key-list wiring; and, in docker under the Pod's security context (non-root, caps dropped, no-new-privileges, volume subpaths), that an RSA key (like a PIV card's) logs in and opens a shell, a key not on the list is refused, and the host key fingerprint is identical after the container is restarted on the same volume (so no host-key warning).

Not verified: a real Gateway IP / Istio-provisioned LoadBalancer or that Istio accepts the TCPRoute (needs the cluster; check Gateway/Route status), real Remote-SSH from the Workstation, a real smartcard (agent forwarding and PIV signing), and that the Workstation has no Kubernetes API access (the design needs none: only the Gateway IP and port 2201 over TCP, and the Pod carries no API credentials). The ambient-mesh L4 path to a StatefulSet Pod via a ClusterIP Service is also untested. No image change was needed.
