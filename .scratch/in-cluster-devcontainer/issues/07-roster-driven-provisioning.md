# 07: Roster-driven provisioning

**What to build:** The Roster in Git drives the creation of every admin's Pod, volume, key list, Service and Gateway route, so adding or removing an admin is a merge.

**Blocked by:** 06

**Status:** resolved

- [x] Each Roster entry carries a name, a smartcard public key, a port and optional resource overrides
- [x] A Flux `ResourceSet` generates each admin's resources from the Roster, and no per-admin manifest is hand-written
- [x] Adding a second admin by merge creates a working Pod they can reach on their own port
- [x] Removing an entry removes that admin's Pod and Gateway route
- [x] One admin's session cannot reach another admin's Pod or volume

## Answer

Done. The hand-written per-admin manifests are gone; `manifests/devcontainer/` now holds the Namespace, Site Config, `roster.yaml` and `resourceset.yaml`.

- **Roster** (`roster.yaml`): a Static `ResourceSetInputProvider` (fluxcd.controlplane.io/v1) whose `defaultValues.admins` is the list; each entry has `name`, `port`, `publicKey` and optional `resources` (any of requests/limits cpu/memory). It stays a plain file in Git.
- **ResourceSet** (`resourceset.yaml`): `inputsFrom` the Roster; `resourcesTemplate` (Go template, `<< >>` delimiters) ranges over `inputs.admins` and renders the shared Gateway plus, per admin, a key-list ConfigMap, headless Service, ClusterIP Service, TCPRoute and StatefulSet (with its `state` volume claim template). Objects are named `devc-<name>...`, listener `ssh-<name>`, Pods and Services select on `devcontainer/admin=<name>`. Removal works through the ResourceSet inventory (pruned when the entry disappears).
- **Gateway tradeoff.** A template only sees one input set at a time, and a Gateway's listeners are a list inside one object. Options: (a) one input set per admin and one Gateway per admin: trivially templated and each admin is independent, but every Gateway gets its own LoadBalancer IP, which breaks ADR 0001's single shared IP; (b) one input set per admin and a hand-maintained shared Gateway: needs a per-admin hand edit, which is what this ticket removes; (c) chosen: the whole Roster is one input set and the template `range`s over it, so one shared Gateway gets one generated listener per admin (one IP) and the admin's route attaches by `sectionName`. Cost: Roster-wide rendering means a malformed entry (duplicate port or name, bad key) breaks the whole ResourceSet, not just that admin, and a Roster must have at least one admin (a Gateway with no listeners is invalid). Per-input-set pruning is still per object, so removal still drops only that admin's objects and listener.
- **Test seam** (`tests/cluster.sh`, `tests/cluster_policy.py`, `tests/rosters/`): renders with the real `flux-operator build resourceset` CLI (v0.52.0, on PATH here; the script fails clearly if it is missing) for 1 admin, 2 admins (bob overrides resources), 2 minus alice, and the committed Roster. Each output goes through kubeconform and the policy checks, now run per admin: Pod Security restricted, volume layout, Site Config, resources with the Roster's overrides, key list equal to the Roster's key, one listener/route/Service/Pod chain per admin. Isolation checks assert distinct Pod, claim, key-list, port and selector, that a Pod mounts only its own key list plus Site Config, references no PVC directly, and mentions no other admin's name or key; the removal case asserts nothing named for alice remains. Run: `bash tests/cluster.sh`.
- **Not proven here** (needs a real Flux cluster): that the Operator accepts the ResourceSet and prunes on removal, that the Static provider's defaultValues drive it identically to the CLI's rendering, Istio's handling of a multi-listener Gateway and its TCPRoutes, and network-level isolation (nothing here blocks admin-to-admin traffic inside the cluster; the Pods can still reach each other's sshd, which only accepts that admin's key. A NetworkPolicy would tighten this and is not in this ticket).
- **Follow-ups worth noting**: removing an entry deletes the StatefulSet but not its PVC (StatefulSet controller owns it; retained on purpose so a mistaken merge does not destroy the volume, deleted by hand); the ResourceSet has no `serviceAccountName`, so it applies as the Operator; set one with narrow RBAC once the Gitops repository defines it.
