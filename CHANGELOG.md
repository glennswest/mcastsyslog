# Changelog

All notable changes to mcastsyslog are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/), and the project follows
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### 2026-08-24
- **feat:** Read-only REST API (`/api/v1`) — events, search, one event by id,
  around-a-moment, hosts, tags, fleet, summary, stats, the type definitions,
  and a Server-Sent Events live tail. Filters parse into the same `FilterState`
  the window uses, so HTTP and the UI cannot give different answers. Off by
  default, bound to `127.0.0.1`, no CORS header. Documented in `docs/API.md`.
- **feat:** A small browser console at `/`, so the API is usable without
  writing a client first.
- **fix:** The event JSON encoding never emitted `id`, which made the
  documented `/events/{id}` endpoint unreachable — there was no way to learn an
  id. It is written now, and deliberately ignored on import since it means
  nothing in another viewer's store.
- **docs:** `docs/EXPORT.md` — the event encoding written down as a format, so
  `must-gather` can produce the same shape.
- **fix:** `PRAGMA auto_vacuum` was being set after `journal_mode = WAL`, which
  makes SQLite accept it and silently do nothing — even on a database with no
  tables. Retention would delete rows forever while the file never shrank, so
  the size budget could never be met. The pragma order is now load-bearing and
  says so, an existing database is converted with a one-time VACUUM on the
  retention queue, and the size loop stops if a pass reclaims nothing rather
  than grinding the corpus away against a budget it cannot reach.
- **test:** 60 tests over the parser, timestamps, the store, filter/SQL
  agreement and the export encoding.
- **feat:** Wire layer — `LogEvent`, `Severity`, a tolerant byte-level RFC 5424
  parser that never drops a frame, and `Timestamp` parsing/rendering that keeps
  the microseconds the node sends.
- **feat:** `MulticastReceiver` — BSD sockets, a membership per IPv4 interface,
  re-joined on every path change and again every two seconds, a dedicated
  receive thread, and a bounded hand-off that never reaches the node.
- **feat:** `EventStore` / `EventReader` — SQLite schema and indexes, batched
  inserts, index-driven filters, FTS5 word search, cancellable substring scan,
  fleet summary and size/age retention with incremental vacuum.
- **build:** xcodegen `project.yml`, app bundle metadata, entitlements and a
  `Makefile`. The app is unsandboxed by intent — see `CLAUDE.md`.
- **docs:** Amended `docs/SPEC.md` storage section — redb (a Rust crate) replaced
  by SQLite, so the whole application can be one native Swift target. The index
  design, the receive-time clustering key and the front-truncating retention
  delete are unchanged; they are properties of the access pattern, not of the
  store.
- **docs:** Added project `CLAUDE.md` with the work plan, architecture, version
  locations and the spec's non-negotiable properties.
