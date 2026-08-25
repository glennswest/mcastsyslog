---
description: What is going wrong across the stormcos fleet right now
---

Find out what is going wrong on the fleet, using the mcastsyslog tools.

1. `fleet_status` — which nodes are talking, and which are unhappy.
2. `log_summary` with `min_severity: error` and `last: 1h` — how much, and where.
3. For each node with errors, `search_logs` with `min_severity: error` for the
   actual lines.
4. If anything looks like a fault rather than noise, `analyse_sequence` scoped
   to that node — it will say what phase the node was in and what every other
   node was saying at the same instant.

Report what is wrong, on which nodes, and since when. Say plainly when nothing
is wrong. Distinguish the node's own notices about its volume — collapsed
repeats and rate-limit drops — from failures: those are the node defending the
wire, not something breaking.
