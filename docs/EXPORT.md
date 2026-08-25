# The event encoding

What the viewer writes when you export, what it reads when you open a bundle,
and what the REST API serves. It is written down because it is meant to be a
format rather than an implementation detail: `stormblock must-gather` should be
able to produce the same shape from the node side, so that a bundle collected
at a node and a bundle exported from the viewer are the same kind of thing.

**Format identifier:** `mcastsyslog-events-v1`

## The file

Newline-delimited JSON — one object per line. The first line is a manifest;
every line after it is an event.

Newline-delimited rather than one big array, because it can be appended to
while it is being written, read with `grep`, streamed without holding it in
memory, and truncated by a crash without becoming unparseable.

```
{"mcastsyslog":{"format":"mcastsyslog-events-v1","version":"0.1.0","exported":"2026-08-24T21:50:02.000000Z","group":"239.255.42.1:5514","filter":{…}}}
{"recv_ns":1787608031123456000,"recv":"2026-08-24T21:47:11.123456Z","host":"storm-01",…}
{"recv_ns":1787608031224001000,"recv":"2026-08-24T21:47:11.224001Z","host":"storm-02",…}
```

A reader should treat any line carrying an `mcastsyslog` key as a manifest and
anything else with a `message` as an event. Lines it cannot parse should be
skipped rather than failing the file — the same reason the wire parser keeps a
frame it cannot read.

## An event

| Field | Type | Notes |
|---|---|---|
| `recv_ns` | integer | receive time, Unix nanoseconds. **Never absent.** |
| `recv` | string | the same, RFC 3339 UTC with microseconds |
| `sent_ns` | integer | the sender's time. **Absent** when the node had no clock. |
| `sent` | string | the same, RFC 3339 UTC |
| `host` | string | what the frame calls itself; the source address if it sent `-` |
| `source` | string | the address the datagram actually came from |
| `tag` | string | the workload the line came from |
| `severity` | integer | 0 emergency … 7 debug |
| `severity_name` | string | the same, spelled out |
| `facility` | integer | 16 (`local0`) for a stormcos node |
| `message` | string | |
| `flags` | array | absent when empty |
| `repeated` | integer | on a collapsed-repeat or rate-limit notice: how many |
| `raw_base64` | string | the frame verbatim. Present **only** when `malformed`. |
| `id` | integer | the viewer's row number. See below. |

Both times are carried twice on purpose: as nanoseconds, which is what the
store holds and what round-trips exactly, and as RFC 3339, which is what a
person reading the file needs. A reader should prefer the `_ns` form and fall
back to parsing the string.

`sent_ns` is **absent rather than null** when the node's clock was not set. That
is the node saying so, and it is not the same as a time of zero.

### `flags`

| Value | Meaning |
|---|---|
| `malformed` | the frame did not parse as RFC 5424. It is kept verbatim in `raw_base64` — never dropped, because a viewer that hides what it cannot parse hides exactly the interesting failures. |
| `clock_unset` | the node sent the nil timestamp, or a time from before 2020. Ordered by receive time. |
| `collapsed_repeat` | the node collapsed a run of identical lines; `repeated` carries how many. |
| `rate_limited` | the node's token bucket ran dry — 200 lines/s sustained, 2000 banked — and it is announcing what it held back in `repeated`. |

The last two are facts about the node, not noise. A reader should keep them.

### `id`

The viewer's own row number, which is what the REST API's `/events/{id}`
addresses. It means nothing in another viewer's store, so it is **written but
ignored on import**: importing a bundle assigns fresh ids. Producers other than
the viewer should omit it.

## The manifest

```json
{"mcastsyslog": {
  "format": "mcastsyslog-events-v1",
  "version": "0.1.0",
  "exported": "2026-08-24T21:50:02.000000Z",
  "group": "239.255.42.1:5514",
  "filter": {"ordering": "senderTime", "range": "Last 15m", "hosts": ["storm-01"]}
}}
```

`filter` records what the export was a view of, so a bundle attached to an issue
carries the question it was the answer to. It is descriptive: a reader does not
have to understand it, and should not re-apply it.

## Plain text

The other export format is not a data format and does not round-trip. It exists
for pasting into an issue where JSON would be unreadable:

```
2026-08-24 21:47:11.123456  ERR   storm-01        stormblock    ERROR ublk queue 3 reset after io timeout
2026-08-24 21:47:11.224001  INFO  storm-02        registry      registry: pulled vol-421:latest, 3 layers cached
2026-08-24 21:47:12.001200  INFO  storm-09        kernel        garbled frame   [malformed] [clock unset]
```

The flags are appended in brackets, because a line that is there because it
could not be parsed should not read as though it parsed.
