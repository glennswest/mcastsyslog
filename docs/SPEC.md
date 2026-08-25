# mcastsyslog — a viewer for a fleet that is talking

**Status:** implemented. See the repository root for the application.

## The problem it solves

A stormcos node logs to three places and waits on none of them: a file per
workload (the record), a non-blocking console (a convenience), and a multicast
syslog group (the wire). The wire exists because the other two are only useful
if you are already at the node — and the moment you most need a node's logs is
the moment you cannot get to it.

The failure this replaces is worth stating plainly, because it is what the
design is shaped around: a console with no reader blocks on its first full
buffer, and then *every* write to it blocks. Not the logging — the program. A
storage engine stops serving, a shell never prints its prompt, and the node
looks hung while being perfectly healthy apart from the thing meant to tell you
about it. A slow console has taken down production systems. Nothing in this
path may ever wait.

Multicast follows from that. A node emits to a group and does not know or care
who is listening; a watcher joins the group and does not have to be registered
anywhere. Nodes need no configuration to be watched, watchers need no
configuration to watch, and neither can slow the other down. Zero, one or ten
viewers make no difference to the node.

## The wire

- **Group:** `239.255.42.1:5514` by default — administratively scoped, so it
  stays inside the site. Overridable per node with `stormpump.syslog=<host:port>`
  on the kernel command line; a unicast address there works identically.
- **TTL 4**, loopback delivery on, so a watcher on the node itself sees the
  stream too.
- **Framing:** RFC 5424.
  `<PRI>1 TIMESTAMP HOST TAG - - - MESSAGE`
  - `PRI` = `local0` (facility 16) × 8 + severity.
  - Severity is derived from the line: `ERROR`/`FATAL` → 3, `WARN` → 4,
    `DEBUG`/`TRACE` → 7, otherwise 6. Collapsed-repeat and rate-limit notices
    are 5 (notice) and 4 (warning).
  - `TIMESTAMP` is RFC 3339 UTC with microseconds — **or the NILVALUE `-`**
    when the node's clock is obviously unset (before 2020). A node syncs NTP in
    the initramfs, before the root filesystem is mounted, precisely so this is
    real; when it could not, it says so rather than inventing a plausible time.
  - `TAG` is the workload the line came from (`stormpump`, `stormblock`,
    `registry`, …).
- **One line per datagram**, truncated at 8 KiB. Anything longer is a payload,
  not a log.

The sender never retries, never buffers for delivery and never blocks. A
datagram nobody takes is not the node's problem — the file still has the line,
and `must-gather` still collects it.

### What the node already does about volume

The viewer does not have to defend itself against a node in a loop, because the
node defends the wire:

- **Repetition** collapses. A run of identical lines becomes one line plus
  `last message repeated N time(s)`.
- **Rate** is limited per source by a token bucket — 200 lines/s sustained,
  2000 banked — and what was held back is announced:
  `N message(s) dropped — over 200 lines/s`.

Both are visible in the stream. A viewer should render them distinctly: they
are facts about the node, not noise.

## The application

A macOS app. Native SwiftUI; no Electron, no browser, no server to run.

### Receiving

- Joins the group on every interface with an IPv4 address, and re-joins when
  the interface set changes (waking from sleep, changing networks).
- Parses RFC 5424, tolerantly: a frame that does not parse is kept verbatim
  with severity `info` and a `malformed` flag rather than dropped. A viewer
  that hides what it cannot parse hides exactly the interesting failures.
- Records **both** times: the sender's timestamp and the receive time. They
  differ, and the difference is information — a node replaying a boot's backlog
  after its network came up sends an hour of lines in a second, and that is
  correct behaviour, not a fault. Default ordering is by sender time; the
  viewer can switch to receive time, and should show when they disagree by more
  than a few seconds.
- A node with a nil timestamp is ordered by receive time and flagged
  `clock unset`.

### Storing

SQLite, through the `libsqlite3` already on the machine — an embedded,
single-file, transactional store. Chosen because the alternative to embedding a
store is inventing one, and this is a log viewer, not a database.

> **Amended 2026-08-24.** This section originally specified
> [redb](https://github.com/cberner/redb). redb is a Rust crate, and the viewer
> is a Swift application; keeping it would have meant a Rust core behind a C
> ABI for no gain in the shape below. Every structural decision here — ordered
> composite keys, filters as index intersections, retention as a
> front-truncating range delete — survived the move unchanged, because they are
> properties of the access pattern, not of the store.

```sql
CREATE TABLE events (
    id        INTEGER PRIMARY KEY,   -- monotonic at the viewer; the tiebreak
    recv_ns   INTEGER NOT NULL,      -- receive time, Unix ns. Never null.
    sent_ns   INTEGER,               -- sender's time. NULL when the frame said `-`.
    host      TEXT    NOT NULL,
    tag       TEXT    NOT NULL,
    severity  INTEGER NOT NULL,
    facility  INTEGER NOT NULL,
    flags     INTEGER NOT NULL,      -- malformed | clockUnset | repeat | rateLimit
    repeated  INTEGER,               -- N, on a collapsed-repeat or dropped notice
    source    TEXT    NOT NULL,      -- the address the datagram actually came from
    message   TEXT    NOT NULL,
    raw       BLOB,                  -- the frame verbatim, kept when malformed
    -- The time the viewer orders by under the default ordering. A node with no
    -- clock falls back to when we heard it, which is the only answer there is.
    -- Stored rather than computed so the ordering is an index seek.
    event_ns  INTEGER GENERATED ALWAYS AS (COALESCE(sent_ns, recv_ns)) STORED
);

CREATE INDEX events_by_time  ON events (recv_ns, id);
CREATE INDEX events_by_event ON events (event_ns, id);
CREATE INDEX events_by_host  ON events (host, recv_ns, id);
CREATE INDEX events_by_tag   ON events (tag,  recv_ns, id);
CREATE INDEX events_by_sev   ON events (severity, recv_ns, id);
CREATE INDEX events_by_sent  ON events (sent_ns, id);

CREATE VIRTUAL TABLE events_fts USING fts5 (
    message, content='events', content_rowid='id', tokenize='unicode61'
);

-- A directory of what has been heard: which hosts and tags exist, and when each
-- was first and last seen. It exists so the filter menus and the fleet list can
-- populate themselves without scanning the corpus, and so a node that has gone
-- silent — the one most worth selecting — is still in the list.
CREATE TABLE hosts (host TEXT PRIMARY KEY, first_ns INTEGER NOT NULL,
                    last_ns INTEGER NOT NULL, source TEXT);
CREATE TABLE tags  (tag  TEXT PRIMARY KEY, first_ns INTEGER NOT NULL,
                    last_ns INTEGER NOT NULL);

CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
```

The clustering key is receive time, not sender time: it is monotonic at the
viewer, it is never null, and it is the only ordering that cannot be perturbed
by a node with a wrong clock. Sender time is a field, indexed for range queries
when it is present. `id` disambiguates events arriving in the same nanosecond.

**Indexing** is ordered indexes over `(field, recv_ns, id)`, not an inverted
index of documents. A range scan on `events_by_host` for a host gives its
events in time order for free, and combining filters is an intersection of
ordered index ranges — which is exactly the plan SQLite produces for them.

**Search** is FTS5 over the message, which makes token search a prefix lookup
rather than a full read. Substring search that does not fall on a token
boundary falls back to a scan over the time range being viewed — bounded by
what is on screen, not by the corpus, announced as a scan, and cancellable.

**Retention** is by size and age, whichever comes first, defaulting to 2 GiB or
30 days. Enforced by deleting a whole time range from the front, which is one
range delete per index rather than a walk. The database is opened with
`auto_vacuum=INCREMENTAL` so that a delete actually returns the space.

Write settings: WAL, `synchronous=NORMAL`. Events are committed in batches, not
one transaction per datagram — a transaction per datagram would put an fsync in
a path that must never be slow, and losing the last few milliseconds of a
stream on a hard power cut costs nothing the node's own file does not still
have.

### Viewing

The properties that matter, in order:

1. **Live tail that keeps up.** New events append to the view without
   re-querying. The receiving path never touches the UI thread; the UI reads a
   ring of recent events and a read-only database snapshot for anything older.
2. **Filter without re-typing.** Host, tag, severity and time range are
   controls, not query syntax, and they compose. Every filter is an index
   intersection, so narrowing is fast even at millions of events.
3. **Search that admits its limits.** Token search is instant; substring search
   over an unbounded range says it is scanning and can be cancelled. It never
   silently searches less than it was asked to.
4. **Follow one node, or all of them.** A fleet view (nodes as rows, event rate
   and worst severity as columns) that drills into a single node's stream.
5. **Jump to a moment.** Given a timestamp — from a bug report, a ticket, or
   another tool — land on it and show what surrounded it, on every node at
   once. This is the view that makes multicast worth having: one node's failure
   is usually visible in another node's log first.
6. **Export what is on screen** as a file that can be attached to an issue:
   the same shape `must-gather` produces, so the two are interchangeable.

### What it must not do

- **No acknowledgement, no back-pressure, no requests to nodes.** The viewer is
  a listener. A viewer that can ask a node for anything is a viewer that can
  slow a node down, which is the failure this whole path exists to avoid.
- **No writes to the node.** Ever.
- **No dropping what it cannot parse.**

## Relationship to must-gather

`stormblock must-gather` collects the durable side: the files, the volume
inventory, the ublk state, the kernel's account. mcastsyslog collects the live
side, from outside the node, including the part of a boot that happens before
anything on the node can be asked a question.

They should meet in the middle:

- must-gather's bundle should carry the same event encoding, so a bundle can be
  imported into the viewer and searched with the same tools.
- The planned log-volume rotation — each boot gets a fresh log volume, and the
  previous one is scraped into a must-gather bundle and then deleted — means
  every reboot produces a bundle automatically. The viewer should be able to
  open one.

## Open questions

- **Authenticity.** Nothing stops another host from emitting to the group.
  Within a lab that is acceptable; a signed frame (per-node key, signature in a
  structured-data element) would fix it without changing the transport, and is
  worth doing before this leaves a lab.
- **IPv6.** The same design with `ff15::/16`; deferred until a node needs it.
- **Loss.** Multicast UDP loses datagrams under load and says nothing. The
  files remain authoritative, so the fix is not retransmission but making the
  gap visible: a per-source sequence number in a structured-data element would
  let the viewer show `12 events lost` instead of quietly showing fewer.
