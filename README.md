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

- **[docs/SPEC.md](docs/SPEC.md)** — the specification. Wire format, storage
  schema, indexing, retention, the viewer's required properties, and what it
  must not do.

## Status

Specification only. Nothing is built yet.

## Related

- **stormpump** — PID 1 on a stormcos node; owns the log service that emits to
  the group.
- **stormblock** — the storage engine; `stormblock must-gather` collects the
  durable half (files, volume inventory, kernel state, crash dumps) that this
  complements from outside the node.
