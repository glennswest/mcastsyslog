---
description: What every node was saying at one moment
argument-hint: "<timestamp> [seconds either side]"
---

Show what the whole fleet was saying around $1.

Use `logs_around_moment` with `at: $1`. Widen `window` if too little comes back.

Report it as one timeline across all nodes, not per node — the reason this view
exists is that one node's failure is usually visible in another node's log
first, and neither node knows about the other. Call out anything on a *different*
node that lines up with what you were sent looking for.
