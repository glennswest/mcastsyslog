---
description: Walk through a node's most recent boot
argument-hint: "[hostname]"
---

Walk through the most recent boot of $1 (or, if no node was named, use
`list_hosts` and `node_lifecycle` to find the node that booted most recently).

1. `node_lifecycle` for the node — find its boots and how each run ended.
2. `analyse_sequence` for the node. With no explicit `from`, this snaps the
   window to the most recent boot, so the phases and the workload ordering
   describe the boot itself.
3. If the run before this one ended in anything other than a reboot, say so —
   a node that stopped mid-stream and then booted did not restart cleanly.

Describe the boot as a sequence: what came up, in what order, how long each
phase took, and anything unusual. Note if part of it happened before the clock
was real — a node sends the nil timestamp until NTP comes up in the initramfs,
and those lines are ordered by when they were heard rather than when they
happened.
