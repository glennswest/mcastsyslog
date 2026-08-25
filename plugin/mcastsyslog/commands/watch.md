---
description: Follow the fleet's log for a while and report what happened
argument-hint: "[minimum severity]"
---

Follow the live log and report what arrives.

Use `watch_logs` with `min_severity: ${1:-warning}` and `seconds: 60`. It
returns when it has enough or when the time is up, whichever comes first. Call
it again with the `next_since_id` it returns to keep following.

If nothing arrives, say so — a quiet fleet is not a broken viewer. Check
`store_stats` to confirm the viewer is listening and has interfaces joined
before concluding anything is wrong.
