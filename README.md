# mcastsyslog

A macOS viewer for a fleet of stormcos nodes that are talking.

Nodes emit RFC 5424 syslog to a multicast group and do not know or care who is
listening. This joins the group, stores what it hears in an embedded SQLite
database, and shows it live — filtered, searched and indexed, across every node
at once.

The design constraint that shapes everything: **nothing on a node may ever wait
on logging.** A console with no reader blocks on its first full buffer, and
then every write to it blocks — not the logging, the program. A slow console
has taken down production systems. So a node sends datagrams into a group and
moves on; this application is a listener that can never slow a node down, and
never asks a node for anything.

## Building it

Needs Xcode and [xcodegen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`). The Xcode project is generated from `project.yml`
rather than checked in.

```sh
make          # build MCastSyslog.app
make run      # build and launch it
make test     # the test suite
make sim      # synthetic node traffic, for working without a fleet to watch
```

macOS asks once for local network access. Nothing is received until it is
granted.

## The REST API

On by default, bound to `127.0.0.1`. Read-only, no authentication — which is
why the default is loopback. Settings → REST API.

```sh
curl 'localhost:8514/api/v1/events?min_severity=error&last=15m'
curl 'localhost:8514/api/v1/around?at=2026-08-24T21:47:11Z&window=30'
curl 'localhost:8514/api/v1/summary?last=1h'
curl 'localhost:8514/api/v1/lifecycle?host=storm-01&last=24h'
curl 'localhost:8514/api/v1/analysis?host=storm-01&last=1h'
curl -N 'localhost:8514/api/v1/stream?min_severity=warning'
```

There is a small browser console at `http://127.0.0.1:8514/`.

## The analysis

`/api/v1/analysis` reads a whole sequence rather than listing the lines in it —
what happened, in what order, and what was unusual. Against a real node, a boot
comes out as:

```
startup       29.8s    573 events
  +   0.0s  kernel       470 ev    Linux version 6.17.1
  +   0.2s  stormblock    85 ev
  +   0.3s  registry      18 ev    WARN no stormblockmk API token
  +  29.8s  stormpump      4 ev
steady     11368.3s 205739 events
```

It finds boots from the kernel's own banner rather than guessing from silence,
distinguishes a node that rebooted from one that stopped mid-stream, and says
which of its conclusions the node *stated* and which it merely observed. See
**[docs/API.md](docs/API.md)**.

## Claude plugin

`plugin/mcastsyslog` lets Claude read the fleet's log — search it, follow it,
analyse a boot, and see what every node was saying at one moment.

```sh
/plugin marketplace add /path/to/mcastsyslog/plugin
/plugin install mcastsyslog
```

Standard library Python, no dependencies; it talks to the local REST API over
loopback. See **[plugin/mcastsyslog/README.md](plugin/mcastsyslog/README.md)**.

## Clearing the log

Stream → Clear Stored Events (⇧⌘⌫). Over the API it is off by default and needs
three separate yeses — see [docs/API.md](docs/API.md). The nodes are never
touched either way.

## Documentation

- **[docs/SPEC.md](docs/SPEC.md)** — the specification. Wire format, storage
  schema, indexing, retention, the viewer's required properties, and what it
  must not do.
- **[docs/API.md](docs/API.md)** — the REST API: endpoints, filters, the two
  search modes, and what it will never do.
- **[docs/EXPORT.md](docs/EXPORT.md)** — the event encoding, written down so
  `must-gather` can produce the same shape.

## Status

Working. The viewer receives, stores, indexes, searches and exports; the REST
API serves the same questions to a script. See `CHANGELOG.md`.

## Related

- **stormpump** — PID 1 on a stormcos node; owns the log service that emits to
  the group.
- **stormblock** — the storage engine; `stormblock must-gather` collects the
  durable half (files, volume inventory, kernel state, crash dumps) that this
  complements from outside the node.
