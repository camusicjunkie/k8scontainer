# 10: Image update flow

**What to build:** When the Release Owner publishes a new Standard Image tag, the Management Cluster's existing image automation updates the Pod spec, and each admin gets the new image only when they restart their own Pod.

**Blocked by:** 07

**Status:** ready-for-agent

- [ ] A new tag in the Registry updates the Pod spec through the existing image automation
- [ ] A running Pod is not restarted by the update
- [ ] After an admin restarts their Pod it runs the new image and their volume content is intact
- [ ] Rolling back is possible by pinning an earlier tag
