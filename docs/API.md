# The REST API

A read-only HTTP interface to what the viewer has heard. It exists so the same
questions the window answers can be asked by a script, a dashboard, or another
tool — without a second copy of the parsing, the filters or the index.

**It is off by default.** Turn it on in Settings → REST API. It binds to
`127.0.0.1` unless you explicitly confirm otherwise.

```
http://127.0.0.1:8514/api/v1
```

## What it will never do

The same rules the viewer has, for the same reason:

- **Only `GET` and `HEAD` are routed.** Everything else is `405`, and there is
  no endpoint behind the guard that could mutate anything if one got through.
- **Nothing it can reach has a path to a node.** The API can read the store and
  report status. It cannot transmit, and there is no setting that makes it able
  to.
- **No CORS header is sent.** With one, any page you happened to be visiting
  could read your whole fleet's logs out of your browser. Use `curl`, or the
  console at `/`.
- **No authentication**, which is exactly why the default is loopback. Serving
  on every interface hands every line from every node to anything that can
  reach the Mac. The settings pane makes you confirm that.

## Endpoints

| Endpoint | What it answers |
|---|---|
| `GET /api/v1` | the endpoint list, with parameters |
| `GET /api/v1/health` | is it listening, on what, over which interfaces |
| `GET /api/v1/types` | severities, flags, search modes, orderings, event fields |
| `GET /api/v1/events` | retrieve and search |
| `GET /api/v1/events/{id}` | one event |
| `GET /api/v1/search` | an alias for `/events` |
| `GET /api/v1/around` | everything around a moment, on every node at once |
| `GET /api/v1/hosts` | every node ever heard from |
| `GET /api/v1/tags` | every workload tag ever heard |
| `GET /api/v1/fleet` | nodes as rows: rate, worst severity, last seen |
| `GET /api/v1/summary` | a rollup of whatever the filters match |
| `GET /api/v1/stats` | store, receiver and retention numbers |
| `GET /api/v1/stream` | Server-Sent Events — the live tail |
| `GET /api/v1/lifecycle` | boots, clock syncs, faults and silences, per node |
| `GET /api/v1/analysis` | a deep dive of a whole sequence |
| `GET /api/v1/clear` | delete everything stored. Off by default; see below |
| `GET /` | a small browser console |

## Filters

Every filtering endpoint (`/events`, `/search`, `/summary`, `/around`,
`/stream`) takes the same parameters, and they compose.

| Parameter | Meaning |
|---|---|
| `host` | one or more hostnames. Repeat the parameter or comma-separate: `host=a&host=b` and `host=a,b` are the same. |
| `tag` | one or more workload tags |
| `severity` | one or more severities, by name or number. `error`, `warn`, `fatal` and `trace` are accepted alongside the RFC's names. |
| `min_severity` | everything **at least** this severe. `min_severity=warning` is warnings, errors, criticals, alerts and emergencies. |
| `flag` | require a flag: `malformed`, `clock_unset`, `collapsed_repeat`, `rate_limited` |
| `q` | search text |
| `mode` | `tokens` (default) or `substring` — see below |
| `from`, `to` | time bounds. RFC 3339, `YYYY-MM-DD HH:MM:SS`, a bare epoch number, or a relative span like `-15m`. |
| `last` | a span ending now, instead of `from`/`to`: `15m`, `2h`, `1d` |
| `order` | `sender` (default) or `receive` — which of the two times to sort and bound by |
| `limit` | how many to return. Default 200, **capped at 10000**. |
| `since_id` | only events after this id, oldest first. How to tail — see below. |

Every response echoes a `query` object showing how the parameters were actually
read, so you can see what the server understood rather than assume.

### The two search modes

They are not interchangeable, and the API says which one ran:

- **`tokens`** — the FTS5 index. Whole words and word prefixes. Instant at any
  corpus size. `q=vol` finds `vol-421`, because `vol` is a token and a prefix.
- **`substring`** — a scan over the messages in the time range. Finds anything,
  including things that do not fall on a token boundary: `q=21&mode=substring`
  finds `vol-421`, which `tokens` cannot.

`"scanned": true` in the response means the second one ran. Bound it with
`last` or `from`/`to` — the scan is bounded by the time range, not by the
corpus.

## Tailing

An HTTP request returns once, so following the log works with a cursor rather
than a held-open connection. Every `/events` response carries `next_since_id`;
pass it back to ask what is new.

```bash
# Start from now rather than from the beginning of history
CURSOR=$(curl -s localhost:8514/api/v1/health | jq .newest_id)

while true; do
  PAGE=$(curl -s "localhost:8514/api/v1/events?since_id=$CURSOR&min_severity=warning")
  echo "$PAGE" | jq -r '.events[] | "\(.recv) \(.host) \(.message_plain // .message)"'
  CURSOR=$(echo "$PAGE" | jq .next_since_id)
  sleep 2
done
```

With `since_id`, events come back **oldest first** — a tail reads forward.
Without it, the newest page comes back and reads like the bottom of a log.

Nothing to hang, nothing to reconnect, and asking twice with the same cursor
gives the same answer — which `/stream` cannot promise. `/stream` remains the
right thing for a browser.

## The lifecycle

```bash
curl 'localhost:8514/api/v1/lifecycle?host=storm-01&last=24h'
```

Boots, clock syncs, clock resets, faults and silences, derived from the stream.
Nothing is asked of a node.

Every marker says whether it was **`stated`** — the node said so — or inferred:

- `kernel_boot` (**stated**) — the kernel prints `Linux version …` exactly once
  per boot. The most reliable boot marker there is.
- `boot` — inferred from silence, or from being the first thing ever heard.
- `clock_sync` — the frame where the nil timestamp stops. That is NTP coming up
  in the initramfs, and it is a real dated point in the boot.
- `clock_reset` — the sender's clock stepped backwards. Marked, because the
  node's sense of time did change, but it does **not** start a run: a node
  running ntpd steps its clock in the middle of a perfectly healthy run.
- `fault` — severity 0–2. The node's own account of something going badly wrong.

`runs` groups those into periods of the node talking, each with an `ending`:

| Ending | Means |
|---|---|
| `running` | still talking |
| `rebooted` | it stopped because it booted again |
| `faulted` | it stopped, and the last thing it said was a fault. As close to "it crashed" as anything outside the node can honestly get. |
| `cut_off` | it stopped mid-stream and said nothing about why. A crash, a power cut and a severed cable look identical from here, and this does not pretend to tell them apart. |
| `quiet` | it stopped, having barely been talking |

`gap` sets how much silence ends a run (default `90s`). Raise it for a fleet
that logs sparsely, or every quiet stretch reads as a reboot.

## The analysis

```bash
curl 'localhost:8514/api/v1/analysis?host=storm-01&last=1h'
```

The deep dive: what happened, in what order, and what was unusual.

When one host is named and no explicit `from`/`at` is given, the window
**snaps to that node's most recent boot** — the sequence is the run, not the
span you happened to ask for. `aligned_to_run` says whether it did, and
`align_to_run=false` turns it off.

| Field | What it is |
|---|---|
| `narrative` | the whole thing in sentences. Read this first. |
| `phases` | `pre_clock` → `startup` → `steady` → `degraded`, with durations and counts. Only when a single host is named: several nodes' sequences overlaid is not one startup. |
| `workloads` | every tag's first appearance and how long after the start — the order things came up in |
| `escalations` | the first event at each severity, worst first |
| `gaps` | the longest silences, with what was said immediately before |
| `findings` | what was unusual, each with a `confidence` |
| `correlations` | for each fault, what every **other** node was saying within ±5s |
| `rate_profile` | events per bucket — the shape of the sequence |
| `clock_skew` | at the start and end. A large skew that shrinks fast is a backlog replay, which is correct behaviour. |

`confidence` is one of `stated` (the node said so), `observed` (the stream shows
it directly) or `suggested` (consistent with the stream, but other explanations
fit). Nothing is asserted at a level the evidence does not support.

## Clearing

```bash
curl 'localhost:8514/api/v1/clear?confirm=yes'
```

The one endpoint that destroys something, and it needs three separate yeses:

1. **Allow clearing the log over the API** must be on in Settings → REST API.
   It is off by default.
2. The API must be bound to `127.0.0.1`. Clearing is refused outright while it
   serves on every interface.
3. `confirm=yes` on the request, so it cannot be hit by a stray link.

The nodes are not touched. What is lost is this viewer's record of what it
heard; the nodes' own files still have every line, and the viewer fills up
again from the group.

In the app it is Stream → Clear Stored Events (⇧⌘⌫), which asks first and says
how much will go.

## Examples

```bash
# What a node said in the last 15 minutes
curl 'localhost:8514/api/v1/events?host=storm-01&last=15m'

# Errors and worse across the fleet, most recent 50
curl 'localhost:8514/api/v1/events?min_severity=error&limit=50'

# Frames that did not parse — kept verbatim, never dropped
curl 'localhost:8514/api/v1/events?flag=malformed'

# What surrounded a moment, on every node at once
curl 'localhost:8514/api/v1/around?at=2026-08-24T21:47:11Z&window=30'

# A rollup of the last hour
curl 'localhost:8514/api/v1/summary?last=1h'

# Which nodes are talking, and which are unhappy
curl 'localhost:8514/api/v1/fleet?window=5m'

# Follow the live tail, filtered
curl -N 'localhost:8514/api/v1/stream?min_severity=warning'
```

Piping to `jq` is the expected use:

```bash
# The loudest node in the last hour
curl -s 'localhost:8514/api/v1/summary?last=1h' | jq -r '.by_host[0].host'

# Every distinct error message, deduplicated
curl -s 'localhost:8514/api/v1/events?min_severity=error&last=1d&limit=10000' \
  | jq -r '.events[].message' | sort -u
```

## Responses

An event is the encoding documented in [EXPORT.md](EXPORT.md), plus an `id`:

```json
{
  "id": 41207,
  "recv_ns": 1787608031123456000,
  "recv": "2026-08-24T21:47:11.123456Z",
  "sent_ns": 1787608031000001000,
  "sent": "2026-08-24T21:47:11.000001Z",
  "host": "storm-01",
  "source": "203.0.113.11",
  "tag": "stormblock",
  "severity": 3,
  "severity_name": "error",
  "facility": 16,
  "message": "ERROR ublk queue 3 reset after io timeout"
}
```

Real nodes emit coloured output — `stormpump` forwards a workload's stdout as it
was written. `message` keeps the escapes, because that is what the node sent;
when they are present, **`message_plain`** carries the same line as a person
would read it. It is absent when the two are identical.

`sent_ns` and `sent` are **absent**, not null, when the node had no clock — it
sent the nil timestamp rather than inventing a plausible time, and the
`clock_unset` flag says so. A `malformed` event carries `raw_base64`: the frame
exactly as it arrived.

A list response wraps them:

```json
{
  "events": [ … ],
  "returned": 200,
  "matched": 41207,
  "matched_exact": false,
  "truncated": true,
  "scanned": false,
  "elapsed_ms": 3.4,
  "query": { "host": ["storm-01"], "limit": 200, "order": "senderTime" }
}
```

`matched_exact: false` means counting stopped at a ceiling rather than walking
the whole corpus to produce a number — `matched` is a floor, not a total. The
API does not round that into something that looks exact.

### `/summary`

```json
{
  "total": 41207,
  "rate_per_second": 11.4,
  "by_severity": [ {"severity": 6, "name": "info", "count": 38112}, … ],
  "by_host":     [ {"host": "storm-01", "count": 14002, "worst_severity_name": "error"}, … ],
  "by_tag":      [ {"tag": "stormblock", "count": 20551, "worst_severity_name": "error"}, … ],
  "flags": {"malformed": 3, "clock_unset": 812, "collapsed_repeat": 44, "rate_limited": 7},
  "lines_the_nodes_held_back": 9931
}
```

`lines_the_nodes_held_back` is the sum of the counts on collapsed-repeat and
rate-limit notices: **lines that exist on the node and were never put on the
wire.** The node's own files still have them. It is reported rather than left to
be inferred from a gap.

### `/stream`

Server-Sent Events. Same filters as `/events`; no `limit` or `last`.

```
event: hello
data: {"version":"0.1.0","endpoint":"239.255.42.1:5514", …}

event: log
data: {"id":41208,"recv":"…","host":"storm-01", …}

: keep-alive
```

Events are published **after** they are written to the store, so the tail and
the history can never disagree about what happened. A comment line every 15
seconds keeps an idle stream from being cut.

This is a tail of the wire, not a replay — use `/events` for history.

## Errors

`4xx` and `5xx` responses carry a JSON body saying what was wrong:

```json
{"error": "`banana` is not a severity — use a name (error, warning, …) or 0–7", "status": 400}
```

| Status | When |
|---|---|
| `400` | a parameter could not be read — the message says which and what would work |
| `404` | no such endpoint, or no event with that id |
| `405` | anything but `GET` or `HEAD` |
| `431` | a request header larger than 64 KiB |
| `500` | the store failed; the message is the underlying error |
