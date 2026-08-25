# CLAUDE.md — mcastsyslog

A native macOS (SwiftUI) viewer for the multicast syslog group that stormcos
nodes emit to. See `docs/SPEC.md` for the specification; this file carries the
work plan, version info and project-specific context.

## Version

**0.2.0** — released 2026-08-25. Pre-1.0, so the API is not yet stable.

Version locations that must match:
- `Sources/MCastSyslog/Support/Version.swift` — `AppVersion.current`
- `project.yml` — `MARKETING_VERSION`
- `plugin/mcastsyslog/.claude-plugin/plugin.json` — `version`
- `plugin/mcastsyslog/mcp/server.py` — `serverInfo.version`
- `CHANGELOG.md` — latest released heading
- git tag `vX.Y.Z`

## Architecture

All Swift. One Xcode project, generated from `project.yml` by
[xcodegen](https://github.com/yonaskolb/XcodeGen) so the project file itself is
not checked in as a merge hazard.

| Target | Kind | What it is |
|---|---|---|
| `MCastSyslog` | macOS app | The viewer. SwiftUI + AppKit. |
| `stormsim` | CLI tool | Emits synthetic RFC 5424 traffic to the group, for testing without a fleet. |
| `MCastSyslogTests` | unit tests | Parser, timestamps, plain text, store, filter/SQL agreement, lifecycle, analysis, export encoding and the REST API. 140 of them. |

Source layout under `Sources/MCastSyslog/`:

- `Wire/` — the RFC 5424 frame. Tolerant parser, severity derivation, nil
  timestamp handling, recognition of the node's collapsed-repeat and
  rate-limit notices.
- `Net/` — `MulticastReceiver`. BSD sockets (`IP_ADD_MEMBERSHIP` per
  interface), a dedicated receive thread, `NWPathMonitor` to trigger re-joins
  when the interface set changes.
- `Store/` — SQLite (the system `libsqlite3`, no third-party dependency).
  Schema, batched writer, index-driven queries, FTS5 token search, retention.
- `plugin/` — the Claude plugin: an MCP server over the local API, plus
  commands. Standard-library Python, no dependencies.
- `API/` — the REST API: a small HTTP/1.1 server on `NWListener`,
  the routes, query-parameter parsing, SSE fan-out and the browser console.
- `App/` — SwiftUI views, view models, export.
- `Support/` — version, formatting, small shared helpers.

### Why sockets and not Network.framework

`NWConnectionGroup` multicast requires the `com.apple.developer.networking.multicast`
managed entitlement, which needs a provisioning profile granted by Apple. BSD
sockets need no entitlement on macOS, and give per-interface control over which
memberships are joined — which the spec requires. macOS 15 still gates local
network traffic behind user consent, so `NSLocalNetworkUsageDescription` is set.

### Why SQLite and not redb

The spec was written against redb, which is a Rust crate. Keeping it would mean
a Rust core behind a C ABI under the SwiftUI app. The index design — ordered
composite keys, filters as index intersections, retention as a front-truncating
range delete — maps onto SQLite indexes essentially one-for-one, and SQLite is
already on the machine. `docs/SPEC.md` has been amended accordingly.

## Work plan

- [x] Amend `docs/SPEC.md` storage section: redb → SQLite
- [x] Project scaffolding — `project.yml`, `Makefile`, Info.plist, entitlements
- [x] `Wire/` — event model and tolerant RFC 5424 parser
- [x] `Net/` — multicast receiver, per-interface joins, re-join on change
- [x] `Store/` — schema, batched writer, queries, FTS5 search, retention
- [x] `App/` — fleet view, event stream, filters, search, jump-to-moment, export
- [x] `stormsim` — synthetic traffic generator
- [x] Tests — parser, store, query, retention
- [x] Build, run, verify against `stormsim`
- [x] REST API — retrieve, search, types, summary, stats, live SSE, console
- [x] JSON document export, cursor tailing, log clearing
- [x] Lifecycle markers — boots, clock syncs, faults, silences
- [x] Analysis — a deep dive of a whole sequence
- [x] Claude plugin — MCP server and commands
- [x] v0.1.0 release
- [x] v0.2.0 release

## Non-negotiables from the spec

These are properties, not preferences. A change that breaks one is a bug.

1. **Never send anything to a node.** No acknowledgement, no back-pressure, no
   requests. The receive socket is never used to transmit.
2. **Never drop an unparseable frame.** It is kept verbatim, severity `info`,
   flagged `malformed`.
3. **Never block the receive thread on the UI, the store, or a lock the UI
   holds.** The receiver hands off to a bounded queue and returns to `recvfrom`.
4. **Never silently search less than asked.** A substring scan announces itself
   and is cancellable; it does not quietly truncate.
5. **Record both times.** Sender and receive time are separate fields, and
   their disagreement is shown, not smoothed over.
6. **Nothing is asserted above the evidence.** The analysis and the lifecycle
   markers distinguish what a node *stated* from what was *observed* from what
   is merely *suggested*, and a run that stopped without explanation is
   reported as `cut_off` rather than as a crash — a crash, a power cut and a
   severed cable look identical from outside.
7. **The REST API is read-only and loopback by default.** Only `GET` and `HEAD`
   are routed, nothing it can reach has a path back to a node, and it sends no
   CORS header — with one, any page the user was visiting could read the whole
   fleet's logs out of their browser.
