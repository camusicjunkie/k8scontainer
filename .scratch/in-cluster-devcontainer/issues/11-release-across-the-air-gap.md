# 11: Release across the air gap

**What to build:** A Release is cut as an image archive plus a checksum with a Review Packet, carried to the Disconnected Side and loaded into its Harbor, so the same Standard Image runs on both networks.

**Blocked by:** 04

**Status:** resolved

- [x] The Release Owner can produce the archive, checksum and Review Packet from a tagged image
- [x] The import into the Disconnected Harbor checks the checksum first and refuses a mismatch
- [x] The imported image has the same digest as the one built on the Connected Side
- [x] The import refuses to overwrite an existing version
