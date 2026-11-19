# Glossary

A devcontainer for Kubernetes and infrastructure administration that runs as a Pod in a cluster instead of as a container on a Docker Host. It is the Kubernetes-native successor to `camusicjunkie/devcontainer` and is delivered by the GitOps repository `camusicjunkie/Gitops`.

## Language

**Workstation**:
The Windows machine an admin sits at, running portable VS Code. It never runs containers itself.

**Standard Image**:
The single devcontainer image every admin uses, the same on both networks.

**Release**:
One versioned build of the Standard Image, produced on the Connected Side and carried to the Disconnected Side as an image archive with its checksum. Releases recur.

**Connected Side**:
The network with Internet access, where Releases are built.

**Disconnected Side**:
The air-gapped network that only receives Releases and never builds anything.

**Management Cluster**:
The cluster on each network that hosts platform automation (Flux image automation) and, now, every admin's Devcontainer Pod.
_Avoid_: tooling cluster, admin cluster

**Devcontainer Namespace**:
The one Kubernetes namespace on the Management Cluster that holds every admin's Devcontainer Pod and its storage.
_Avoid_: tooling namespace

**Devcontainer Pod**:
One admin's own long-lived Pod running the Standard Image, with its own persistent volume. VS Code attaches to it; nothing starts it from `devcontainer.json`.
_Avoid_: devcontainer (on its own), workspace pod, session pod

**Registry**:
The Harbor instance on each network from which the Management Cluster pulls the Standard Image.
_Avoid_: image repository

**Roster**:
The list, kept in Git, of admins entitled to a Devcontainer Pod. Adding an admin to it is what provisions their Pod.

**Release Owner**:
The one person, with a named backup, who decides when a Release is cut and carries it across. Anyone may ask for a Release; only the Release Owner decides.
_Avoid_: release manager, maintainer

## Admin state

**Site Config**:
Settings that belong to a network rather than a person, such as which certificate authorities to trust. Never carried between networks. Distinct from Personal Config.

**Personal Config**:
An individual admin's choices (identity, dotfiles, prompt, aliases, default login targets). Never holds secrets; those belong in the Secrets File.

**Secrets File**:
An admin's own encrypted credentials, unlockable only with their smartcard. Distinct from Personal Config, which is never secret.
_Avoid_: vault, secret store

**State Directory**:
Everything of one admin's that outlives their Devcontainer Pod: Personal Config, Secrets File, cluster logins, workspace and any tools they installed themselves. Held on that admin's own persistent volume.
_Avoid_: profile, home
