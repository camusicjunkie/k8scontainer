# One long-lived Pod per admin on the Management Cluster, with no runtime root

The old design ran one container per admin on a shared Docker Host. The Kubernetes equivalent is one long-lived Devcontainer Pod per admin in a single Devcontainer Namespace on the Management Cluster, each with its own volume holding the State Directory, provisioned from the Roster. Nothing in the Pod may need root after start: the old container let an admin run `sudo` to add a missed tool, and that is replaced by a user-owned `~/.local` on the volume for stopgaps and the next Release for anything worth keeping. This lets the namespace enforce Pod Security `restricted` and keeps the design compatible with the existing Kyverno policies.

## Considered Options

- **Short-lived Pod per session.** Cheaper at rest, but loses running state and complicates the smartcard-unlocked Secrets File and `sshd` host keys.
- **A dedicated tooling cluster.** Isolates the tool from the platform, but the Management Cluster already exists and admins would have one more cluster to run.

## Consequences

- The Devcontainer Pods share a cluster with the platform's automation, so a Management Cluster outage takes admin tooling with it.
- Tools an admin installs themselves persist on their volume but do not reach teammates until they are added to a Release.
- Docker-outside-of-Docker is gone: a Pod has no Docker daemon, and image builds belong in CI.
