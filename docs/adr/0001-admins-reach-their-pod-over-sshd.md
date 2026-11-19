# Admins reach their Devcontainer Pod over `sshd`, not `kubectl exec`

Attaching VS Code with `kubectl exec` is the simplest route into a Pod, but it makes every admin authenticate to the Management Cluster's Kubernetes API and cannot forward the smartcard SSH agent. Many admins are not cluster admins, and the Secrets File is unlocked by an agent signature. Each Devcontainer Pod therefore runs a non-root `sshd`, exposed on one shared Gateway IP with a TCP port per admin, and admins connect with Remote-SSH as they did to the old Docker Host. Only the smartcard public keys recorded in the Roster are accepted.

## Considered Options

- **`kubectl exec` attach (Dev Containers "Attach to Running Kubernetes Container").** Needs no daemon in the image, but requires vSphere SSO and an in-cluster Role for every admin, however narrow, and loses agent forwarding, which breaks the smartcard-unlocked Secrets File.

## Consequences

- The Workstation needs neither `kubectl`, the vSphere plugin nor the Dev Containers extension, only Remote-SSH.
- `sshd` runs as the unprivileged `dev` user on a high port, with host keys kept on the admin's volume so the host key survives restarts.
- The Gateway needs TCP listeners, and the Roster owns the port-per-admin assignment, so the design assumes a small team.
