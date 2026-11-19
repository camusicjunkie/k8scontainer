# 07: Roster-driven provisioning

**What to build:** The Roster in Git drives the creation of every admin's Pod, volume, key list, Service and Gateway route, so adding or removing an admin is a merge.

**Blocked by:** 06

**Status:** ready-for-agent

- [ ] Each Roster entry carries a name, a smartcard public key, a port and optional resource overrides
- [ ] A Flux `ResourceSet` generates each admin's resources from the Roster, and no per-admin manifest is hand-written
- [ ] Adding a second admin by merge creates a working Pod they can reach on their own port
- [ ] Removing an entry removes that admin's Pod and Gateway route
- [ ] One admin's session cannot reach another admin's Pod or volume
