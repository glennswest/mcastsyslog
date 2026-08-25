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

Off by default; turn it on in Settings → REST API. Read-only, bound to
`127.0.0.1`, no authentication — which is why the default is loopback.

```sh
curl 'localhost:8514/api/v1/events?min_severity=error&last=15m'
curl 'localhost:8514/api/v1/around?at=2026-08-24T21:47:11Z&window=30'
curl 'localhost:8514/api/v1/summary?last=1h'
curl -N 'localhost:8514/api/v1/stream?min_severity=warning'
```

There is a small browser console at `http://127.0.0.1:8514/`.

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
