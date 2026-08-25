import Foundation

/// The REST surface over the stored log.
///
/// Read-only, and shaped so a script can ask the same questions the window can:
/// what happened, on which node, around when, and how much of it. Every list
/// endpoint reports what it matched as well as what it returned, and anything
/// that had to scan rather than seek says so — the same honesty the UI owes.
public struct APIRouter {

    public static let version = "v1"
    public static let prefix = "/api/\(version)"

    private let context: APIContext

    public init(context: APIContext) {
        self.context = context
    }

    public func route(_ request: HTTPRequest) -> RouteResult {
        let path = request.path.hasSuffix("/") && request.path.count > 1
            ? String(request.path.dropLast())
            : request.path

        switch path {
        case "/", "/index.html":
            return .response(.html(APIConsole.page))
        case Self.prefix, "/api":
            return .response(.json(index()))
        case "\(Self.prefix)/health":
            return .response(.json(health()))
        case "\(Self.prefix)/types":
            return .response(.json(types()))
        case "\(Self.prefix)/events":
            return .response(events(request))
        case "\(Self.prefix)/search":
            return .response(events(request))
        case "\(Self.prefix)/around":
            return .response(around(request))
        case "\(Self.prefix)/hosts":
            return .response(hosts())
        case "\(Self.prefix)/tags":
            return .response(tags())
        case "\(Self.prefix)/fleet":
            return .response(fleet(request))
        case "\(Self.prefix)/summary":
            return .response(summary(request))
        case "\(Self.prefix)/stats":
            return .response(stats())
        case "\(Self.prefix)/stream":
            return stream(request)
        case "\(Self.prefix)/clear":
            return .response(clear(request))
        case "\(Self.prefix)/lifecycle":
            return .response(lifecycle(request))
        case "\(Self.prefix)/analysis":
            return .response(analysis(request))
        default:
            if path.hasPrefix("\(Self.prefix)/events/"),
               let id = Int64(path.dropFirst("\(Self.prefix)/events/".count)) {
                return .response(event(id: id))
            }
            return .response(.error(404, "Not Found",
                "no such endpoint — GET \(Self.prefix) lists them"))
        }
    }

    // MARK: - Index and types

    private func index() -> Any {
        [
            "name": AppVersion.name,
            "version": AppVersion.current,
            "description": "Read-only access to the multicast syslog this viewer has heard. Nothing here reaches a node.",
            "endpoints": [
                ["path": "\(Self.prefix)/health", "description": "whether it is listening, and on what"],
                ["path": "\(Self.prefix)/types", "description": "severities, flags, search modes, orderings and the event fields"],
                ["path": "\(Self.prefix)/events", "description": "retrieve and search events",
                 "parameters": eventParameterDocs()],
                ["path": "\(Self.prefix)/events/{id}", "description": "one event by id"],
                ["path": "\(Self.prefix)/search", "description": "an alias for /events, for readability"],
                ["path": "\(Self.prefix)/around", "description": "everything around a moment, on every node at once",
                 "parameters": ["at": "a timestamp: RFC 3339, 'YYYY-MM-DD HH:MM:SS', or an epoch number",
                                "window": "seconds either side (default 30)"]],
                ["path": "\(Self.prefix)/hosts", "description": "every node ever heard from, and when"],
                ["path": "\(Self.prefix)/tags", "description": "every workload tag ever heard"],
                ["path": "\(Self.prefix)/fleet", "description": "nodes as rows: rate, worst severity, last seen",
                 "parameters": ["window": "the span to measure over, e.g. 5m, 1h (default 5m)"]],
                ["path": "\(Self.prefix)/summary", "description": "a rollup of whatever the filters match",
                 "parameters": eventParameterDocs()],
                ["path": "\(Self.prefix)/stats", "description": "store, receiver and retention numbers"],
                ["path": "\(Self.prefix)/stream", "description": "Server-Sent Events: the live tail, filtered the same way as /events"],
                ["path": "\(Self.prefix)/lifecycle", "description": "boots, clock syncs, faults and silences, derived from the stream",
                 "parameters": ["host": "narrow to one or more nodes",
                                "last": "the span to look over, e.g. 6h (default 24h)",
                                "from": "explicit lower bound", "to": "explicit upper bound",
                                "gap": "silence that ends a run, e.g. 90s (default 90s)"]],
                ["path": "\(Self.prefix)/analysis", "description": "a deep dive of a whole sequence: phases, the order workloads came up, gaps, escalations, what was unusual, and what other nodes were saying at each fault",
                 "parameters": ["host": "narrow to one or more nodes",
                                "last": "the span to read, e.g. 1h (default 1h)",
                                "from": "explicit lower bound", "to": "explicit upper bound",
                                "at": "centre on a moment instead, with `window` seconds either side",
                                "window": "seconds either side of `at` (default 300)",
                                "align_to_run": "when one host is named, start the window at its most recent boot rather than where `last` reaches back to. On by default unless `from` or `at` is given."]],
                ["path": "\(Self.prefix)/clear", "description": "delete every stored event. Off unless enabled, loopback only, needs confirm=yes",
                 "parameters": ["confirm": "must be `yes`"]],
            ],
            "console": "/",
        ]
    }

    private func eventParameterDocs() -> [String: String] {
        [
            "host": "one or more hostnames; repeat the parameter or comma-separate",
            "tag": "one or more workload tags",
            "severity": "one or more severities, by name or number",
            "min_severity": "everything at least this severe, e.g. warning",
            "flag": "require a flag: malformed, clock_unset, collapsed_repeat, rate_limited",
            "q": "search text",
            "mode": "tokens (indexed, whole words and prefixes) or substring (a scan, finds anything)",
            "from": "lower time bound, inclusive",
            "to": "upper time bound, inclusive",
            "last": "a span ending now instead of from/to, e.g. 15m, 2h, 1d",
            "order": "sender (default) or receive — which of the two times to sort and bound by",
            "limit": "how many to return (default 200, maximum 10000)",
            "since_id": "only events after this id, oldest first — how to tail without a held-open connection. Use the `next_since_id` from the previous response.",
        ]
    }

    /// The types, so a client does not have to guess what a `severity` of 3 is
    /// or which flags exist.
    private func types() -> Any {
        [
            "severities": Severity.allCases.map {
                ["value": Int($0.rawValue), "name": $0.label, "short": $0.short.trimmingCharacters(in: .whitespaces),
                 "is_problem": $0.isProblem]
            },
            "facility": ["value": Int(defaultFacility), "name": "local0",
                         "note": "what a stormcos node emits under"],
            "flags": [
                ["name": "malformed", "bit": Int(EventFlags.malformed.rawValue),
                 "description": "the frame did not parse as RFC 5424 and is kept verbatim in `raw_base64` — never dropped"],
                ["name": "clock_unset", "bit": Int(EventFlags.clockUnset.rawValue),
                 "description": "the node sent the nil timestamp rather than inventing one; ordered by receive time"],
                ["name": "collapsed_repeat", "bit": Int(EventFlags.repeatNotice.rawValue),
                 "description": "the node collapsed a run of identical lines; `repeated` carries how many"],
                ["name": "rate_limited", "bit": Int(EventFlags.rateLimitNotice.rawValue),
                 "description": "the node's token bucket ran dry; `repeated` carries how many lines it held back"],
            ],
            "lifecycle_markers": LifecycleMarker.allCases.map {
                ["value": $0.rawValue, "name": $0.label]
            },
            "run_endings": [
                ["value": "running", "description": "still talking"],
                ["value": "rebooted", "description": "the run ended because the node booted again"],
                ["value": "faulted", "description": "stopped, and the last thing it said was a fault — as close to `it crashed` as anything outside the node can honestly get"],
                ["value": "cut_off", "description": "stopped mid-stream and said nothing about why"],
                ["value": "quiet", "description": "stopped, having barely been talking"],
            ],
            "search_modes": SearchMode.allCases.map {
                ["value": $0.rawValue, "name": $0.label, "description": $0.explanation]
            },
            "orderings": TimeOrdering.allCases.map {
                ["value": $0.rawValue, "name": $0.label]
            },
            "event_fields": [
                ["name": "id", "type": "integer", "description": "monotonic at the viewer; the tiebreak between events in the same nanosecond"],
                ["name": "recv_ns", "type": "integer", "description": "receive time in Unix nanoseconds. Never null."],
                ["name": "recv", "type": "string", "description": "the same, as RFC 3339 UTC"],
                ["name": "sent_ns", "type": "integer|absent", "description": "the sender's time. Absent when the node has no clock."],
                ["name": "sent", "type": "string|absent", "description": "the same, as RFC 3339 UTC"],
                ["name": "host", "type": "string", "description": "what the frame calls itself; falls back to the source address"],
                ["name": "source", "type": "string", "description": "the address the datagram actually came from"],
                ["name": "tag", "type": "string", "description": "the workload the line came from"],
                ["name": "severity", "type": "integer", "description": "0 emergency … 7 debug"],
                ["name": "message", "type": "string"],
                ["name": "flags", "type": "array|absent"],
                ["name": "repeated", "type": "integer|absent"],
                ["name": "raw_base64", "type": "string|absent", "description": "the frame verbatim, present only when malformed"],
            ],
            "format": ExportFormatter.formatIdentifier,
        ]
    }

    // MARK: - Status

    private func health() -> Any {
        let receiver = context.receiverStatus
        let settings = context.settings
        return [
            "status": receiver.isListening ? (receiver.joined.isEmpty && settings.endpoint.isMulticast ? "degraded" : "listening") : "idle",
            "version": AppVersion.current,
            "listening": receiver.isListening,
            "endpoint": settings.endpoint.description,
            "multicast": settings.endpoint.isMulticast,
            "interfaces": receiver.joined.map { ["name": $0.name, "address": $0.address, "loopback": $0.isLoopback] },
            "datagrams": receiver.datagrams,
            "malformed": receiver.malformed,
            "last_received": receiver.lastReceiveNanos.map { Timestamp.format($0, style: .rfc3339UTC) } as Any,
            "error": receiver.lastError as Any,
            "clearing_allowed": settings.allowClearing && !settings.servesRemotely,
            "newest_id": (try? context.withReader { try $0.newestId() }) ?? 0,
        ]
    }

    private func stats() -> HTTPResponse {
        do {
            let store = try context.storeStats()
            let receiver = context.receiverStatus
            let settings = context.settings
            return .json([
                "store": [
                    "events": store.events,
                    "hosts": store.hosts,
                    "bytes": store.bytes,
                    "bytes_human": ByteCount.format(store.bytes),
                    "oldest": store.oldestNanos.map { Timestamp.format($0, style: .rfc3339UTC) } as Any,
                    "newest": store.newestNanos.map { Timestamp.format($0, style: .rfc3339UTC) } as Any,
                ],
                "receiver": [
                    "listening": receiver.isListening,
                    "endpoint": settings.endpoint.description,
                    "datagrams": receiver.datagrams,
                    "bytes": receiver.bytes,
                    "malformed": receiver.malformed,
                    "backlog_batches": receiver.backlog,
                    "interfaces": receiver.joined.map(\.name),
                    "error": receiver.lastError as Any,
                ],
                "retention": [
                    "max_bytes": settings.retention.maxBytes,
                    "max_bytes_human": ByteCount.format(settings.retention.maxBytes),
                    "max_age_days": settings.retention.maxAgeDays,
                    "policy": "size or age, whichever comes first",
                ],
                "api": [
                    "version": AppVersion.current,
                    "live_subscribers": context.live.subscriberCount,
                ],
            ])
        } catch {
            return .error(500, "Internal Server Error", "\(error)")
        }
    }

    // MARK: - Events

    private func events(_ request: HTTPRequest) -> HTTPResponse {
        let parsed: ParsedQuery
        do { parsed = try ParsedQuery(request) } catch { return badRequest(error) }

        do {
            return try context.withReader { reader in
                // With a cursor the question is "what is new", which is a
                // forward walk in arrival order; without one it is "what is the
                // latest", which is the tail of the stream.
                let outcome = parsed.isTail
                    ? try reader.fetchForward(parsed.query)
                    : try reader.fetch(parsed.query)

                // Where to resume. The highest id seen, or — when nothing
                // matched — the cursor that was handed in, so a caller that
                // polls a quiet fleet does not walk backwards.
                let nextSinceId = outcome.events.map(\.id).max()
                    ?? parsed.query.sinceId
                    ?? (try? reader.newestId())
                    ?? 0

                var body: [String: Any] = [
                    "events": outcome.events.map { ExportFormatter.json($0) },
                    "returned": outcome.events.count,
                    "truncated": outcome.truncated,
                    "scanned": outcome.scanned,
                    "elapsed_ms": Double(outcome.elapsedNanos) / 1e6,
                    "next_since_id": nextSinceId,
                    "query": parsed.describe(),
                ]
                if !parsed.isTail {
                    let counted = try reader.countMatching(parsed.query)
                    body["matched"] = counted.count
                    body["matched_exact"] = counted.exact
                }
                return .json(body)
            }
        } catch {
            return .error(500, "Internal Server Error", "\(error)")
        }
    }

    /// Delete everything the viewer has stored.
    ///
    /// Guarded three ways, because this is the one endpoint that destroys
    /// something: it must be switched on deliberately, it refuses when the API
    /// is reachable from other machines, and it needs `confirm=yes` so it
    /// cannot be reached by a stray link or a mistyped path. The nodes keep
    /// their own files either way; what is lost is this viewer's record.
    private func clear(_ request: HTTPRequest) -> HTTPResponse {
        let settings = context.settings
        guard settings.allowClearing else {
            return .error(403, "Forbidden",
                "clearing over the API is off. Turn on \"Allow clearing the log over the API\" in Settings → REST API, or use Stream → Clear Stored Events in the app.")
        }
        guard !settings.servesRemotely else {
            return .error(403, "Forbidden",
                "the API is serving on every interface, so clearing over it is refused. It is available only when the API is bound to 127.0.0.1.")
        }
        guard request.first("confirm") == "yes" else {
            return .error(400, "Bad Request",
                "add `confirm=yes`. This deletes every event this viewer has stored — the nodes keep their own files, but this record is gone.")
        }

        do {
            let before = try context.storeStats()
            try context.clearStore()
            return .json([
                "cleared": true,
                "events_deleted": before.events,
                "bytes_freed": before.bytes,
                "note": "The nodes were not touched. The viewer will fill up again from the group.",
            ])
        } catch {
            return .error(500, "Internal Server Error", "\(error)")
        }
    }

    private func event(id: Int64) -> HTTPResponse {
        do {
            return try context.withReader { reader in
                guard let event = try reader.event(id: id) else {
                    return .error(404, "Not Found", "no event with id \(id)")
                }
                return .json(ExportFormatter.json(event))
            }
        } catch {
            return .error(500, "Internal Server Error", "\(error)")
        }
    }

    private func around(_ request: HTTPRequest) -> HTTPResponse {
        guard let at = request.first("at") else {
            return .error(400, "Bad Request", "`at` is required — a timestamp to land on")
        }
        guard let nanos = Timestamp.parseFlexible(at) else {
            return .error(400, "Bad Request",
                "could not read `\(at)` as a time. Try RFC 3339, 'YYYY-MM-DD HH:MM:SS', or an epoch number.")
        }
        let windowSeconds = Double(request.first("window") ?? "") ?? 30
        let window = Int64(max(0.001, windowSeconds) * 1e9)

        let parsed: ParsedQuery
        do { parsed = try ParsedQuery(request) } catch { return badRequest(error) }

        do {
            return try context.withReader { reader in
                let outcome = try reader.around(nanos: nanos, window: window, query: parsed.query)
                return .json([
                    "at": Timestamp.format(nanos, style: .rfc3339UTC),
                    "at_ns": nanos,
                    "window_seconds": windowSeconds,
                    "events": outcome.events.map { ExportFormatter.json($0) },
                    "returned": outcome.events.count,
                    "truncated": outcome.truncated,
                    "hosts": Set(outcome.events.map(\.host)).sorted(),
                    "elapsed_ms": Double(outcome.elapsedNanos) / 1e6,
                    "note": "Deliberately across every node: one node's failure is usually visible in another node's log first.",
                ])
            }
        } catch {
            return .error(500, "Internal Server Error", "\(error)")
        }
    }

    // MARK: - Directory and rollups

    private func hosts() -> HTTPResponse {
        do {
            return try context.withReader { reader in
                .json(["hosts": try reader.knownHosts()])
            }
        } catch {
            return .error(500, "Internal Server Error", "\(error)")
        }
    }

    private func tags() -> HTTPResponse {
        do {
            return try context.withReader { reader in
                .json(["tags": try reader.knownTags()])
            }
        } catch {
            return .error(500, "Internal Server Error", "\(error)")
        }
    }

    private func fleet(_ request: HTTPRequest) -> HTTPResponse {
        let window = ParsedQuery.duration(request.first("window")) ?? 5 * 60 * 1_000_000_000
        let ordering = ParsedQuery.ordering(request.first("order"))
        let since = Timestamp.now() - window
        do {
            return try context.withReader { reader in
                let nodes = try reader.fleet(sinceNanos: since, ordering: ordering)
                return .json([
                    "window_seconds": Double(window) / 1e9,
                    "since": Timestamp.format(since, style: .rfc3339UTC),
                    "nodes": nodes.map { node in
                        [
                            "host": node.host,
                            "source": node.source,
                            "events": node.events,
                            "rate_per_second": node.rate,
                            "worst_severity": Int(node.worst.rawValue),
                            "worst_severity_name": node.worst.label,
                            "last_seen": node.lastNanos > 0
                                ? Timestamp.format(node.lastNanos, style: .rfc3339UTC) : nil as Any? as Any,
                            "clock_unset": node.clockUnset,
                            "malformed": node.malformed,
                        ]
                    },
                    "talking": nodes.filter { $0.rate > 0 }.count,
                ])
            }
        } catch {
            return .error(500, "Internal Server Error", "\(error)")
        }
    }

    private func summary(_ request: HTTPRequest) -> HTTPResponse {
        let parsed: ParsedQuery
        do { parsed = try ParsedQuery(request) } catch { return badRequest(error) }

        do {
            return try context.withReader { reader in
                let summary = try reader.summary(parsed.query)
                return .json([
                    "total": summary.total,
                    "rate_per_second": summary.rate,
                    "first": summary.firstNanos.map { Timestamp.format($0, style: .rfc3339UTC) } as Any,
                    "last": summary.lastNanos.map { Timestamp.format($0, style: .rfc3339UTC) } as Any,
                    "by_severity": summary.bySeverity.map {
                        ["severity": Int($0.severity.rawValue), "name": $0.severity.label, "count": $0.count]
                    },
                    "by_host": summary.byHost.map {
                        ["host": $0.host, "count": $0.count,
                         "worst_severity": Int($0.worst.rawValue), "worst_severity_name": $0.worst.label]
                    },
                    "by_tag": summary.byTag.map {
                        ["tag": $0.tag, "count": $0.count,
                         "worst_severity": Int($0.worst.rawValue), "worst_severity_name": $0.worst.label]
                    },
                    "flags": [
                        "malformed": summary.malformed,
                        "clock_unset": summary.clockUnset,
                        "collapsed_repeat": summary.collapsedRepeats,
                        "rate_limited": summary.rateLimited,
                    ],
                    "lines_the_nodes_held_back": summary.linesAccountedFor,
                    "note": "`lines_the_nodes_held_back` is the sum of the counts on collapsed-repeat and rate-limit notices: lines that exist on the node and were never put on the wire.",
                    "query": parsed.describe(),
                ])
            }
        } catch {
            return .error(500, "Internal Server Error", "\(error)")
        }
    }

    // MARK: - Live

    private func stream(_ request: HTTPRequest) -> RouteResult {
        let parsed: ParsedQuery
        do { parsed = try ParsedQuery(request) } catch { return .response(badRequest(error)) }

        let handle = EventStreamHandle()
        context.live.subscribe(handle, filter: parsed.filter, ordering: parsed.query.ordering)
        handle.send(event: "hello", json: [
            "version": AppVersion.current,
            "endpoint": context.settings.endpoint.description,
            "filter": parsed.describe(),
            "note": "Events appear as they arrive. This is a tail of the wire, not a replay — use /events for history.",
        ])
        return .eventStream(handle)
    }

    /// Where each node's runs begin and end, and what it said at the seams.
    private func lifecycle(_ request: HTTPRequest) -> HTTPResponse {
        let now = Timestamp.now()
        var from = now - 24 * 3600 * 1_000_000_000
        var to = now
        do {
            if let last = request.first("last") {
                guard let span = ParsedQuery.duration(last) else {
                    return .error(400, "Bad Request", "`\(last)` is not a span — try 6h, 2d, or a number of seconds")
                }
                from = now - span
            } else {
                if let explicit = try ParsedQuery.time(request.first("from"), name: "from") { from = explicit }
                if let explicit = try ParsedQuery.time(request.first("to"), name: "to") { to = explicit }
            }
        } catch {
            return badRequest(error)
        }

        var policy = LifecyclePolicy.default
        if let gap = request.first("gap") {
            guard let span = ParsedQuery.duration(gap) else {
                return .error(400, "Bad Request", "`gap` is not a span — try 90s, 5m")
            }
            policy.gapNanos = span
        }
        let hosts = Set(request.list("host"))

        do {
            return try context.withReader { reader in
                let report = try reader.lifecycle(from: from, to: to, hosts: hosts, policy: policy)
                return .json([
                    "from": Timestamp.format(report.fromNanos, style: .rfc3339UTC),
                    "to": Timestamp.format(report.toNanos, style: .rfc3339UTC),
                    "gap_seconds": Double(policy.gapNanos) / 1e9,
                    "truncated": report.truncated,
                    "markers": report.markers.map { marker in
                        var object: [String: Any] = [
                            "id": marker.id,
                            "marker": marker.marker.rawValue,
                            "label": marker.marker.label,
                            "stated": marker.stated,
                            "host": marker.host,
                            "at": Timestamp.format(marker.timeNanos, style: .rfc3339UTC),
                            "recv": Timestamp.format(marker.recvNanos, style: .rfc3339UTC),
                            "severity": Int(marker.severity.rawValue),
                            "severity_name": marker.severity.label,
                            "message": marker.message,
                        ]
                        if marker.sentNanos == nil { object["clock_unset"] = true }
                        if let gap = marker.gapNanos {
                            object["silent_for_seconds"] = Double(gap) / 1e9
                        }
                        return object
                    },
                    "runs": report.runs.map { run in
                        [
                            "host": run.host,
                            "started": Timestamp.format(run.startNanos, style: .rfc3339UTC),
                            "last_seen": Timestamp.format(run.lastNanos, style: .rfc3339UTC),
                            "duration_seconds": Double(run.durationNanos) / 1e9,
                            "ending": run.ending.rawValue,
                            "ending_label": run.ending.label,
                            "faults": run.faults,
                            "started_without_a_clock": run.startedWithoutAClock,
                            "clock_came_up": run.clockSyncNanos.map {
                                Timestamp.format($0, style: .rfc3339UTC) } as Any,
                            "worst_severity_name": run.worst.label,
                        ]
                    },
                    "note": "Derived from the stream, never asked of a node. `cut_off` means the node stopped mid-stream and said nothing about why — a crash, a power cut and a severed cable look identical from outside, and this does not pretend to tell them apart.",
                ])
            }
        } catch {
            return .error(500, "Internal Server Error", "\(error)")
        }
    }

    /// The deep dive.
    private func analysis(_ request: HTTPRequest) -> HTTPResponse {
        let now = Timestamp.now()
        var from = now - 3600 * 1_000_000_000
        var to = now
        do {
            if let at = request.first("at") {
                guard let centre = Timestamp.parseFlexible(at) else {
                    return .error(400, "Bad Request", "could not read `at=\(at)` as a time")
                }
                let window = Int64((Double(request.first("window") ?? "") ?? 300) * 1e9)
                from = centre - window
                to = centre + window
            } else if let last = request.first("last") {
                guard let span = ParsedQuery.duration(last) else {
                    return .error(400, "Bad Request", "`\(last)` is not a span — try 1h, 30m, 2d")
                }
                from = now - span
            } else {
                if let explicit = try ParsedQuery.time(request.first("from"), name: "from") { from = explicit }
                if let explicit = try ParsedQuery.time(request.first("to"), name: "to") { to = explicit }
            }
        } catch {
            return badRequest(error)
        }
        guard to > from else {
            return .error(400, "Bad Request", "the window ends before it begins")
        }

        let hosts = Set(request.list("host"))
        do {
            return try context.withReader { reader in
                let alignToRun = request.bool("align_to_run") ?? (request.first("from") == nil && request.first("at") == nil)
                let a = try reader.analyse(from: from, to: to, hosts: hosts, alignToRun: alignToRun)
                return .json(Self.encode(a))
            }
        } catch {
            return .error(500, "Internal Server Error", "\(error)")
        }
    }

    static func encode(_ a: SequenceAnalysis) -> [String: Any] {
        func at(_ nanos: Int64) -> String { Timestamp.format(nanos, style: .rfc3339UTC) }

        return [
            "from": at(a.fromNanos),
            "to": at(a.toNanos),
            "duration_seconds": Double(a.toNanos - a.fromNanos) / 1e9,
            "aligned_to_run": a.alignedToRun,
            "hosts": a.hosts,
            "total_events": a.totalEvents,
            // The whole thing in sentences, first, because that is what someone
            // reading this at 3am actually wants.
            "narrative": a.narrative,
            "phases": a.phases.map {
                [
                    "phase": $0.kind.rawValue,
                    "started": at($0.startNanos),
                    "ended": at($0.endNanos),
                    "duration_seconds": Double($0.durationNanos) / 1e9,
                    "events": $0.events,
                    "worst_severity_name": $0.worst.label,
                    "note": $0.note,
                ]
            },
            "workloads": a.debuts.map {
                [
                    "tag": $0.tag,
                    "first_seen": at($0.firstNanos),
                    "offset_seconds": Double($0.offsetNanos) / 1e9,
                    "last_seen": at($0.lastNanos),
                    "events": $0.events,
                    "worst_severity_name": $0.worst.label,
                ]
            },
            "escalations": a.escalations.map {
                [
                    "severity": Int($0.severity.rawValue),
                    "severity_name": $0.severity.label,
                    "at": at($0.atNanos),
                    "offset_seconds": Double($0.offsetNanos) / 1e9,
                    "host": $0.host,
                    "tag": $0.tag,
                    "message": $0.message,
                    "event_id": $0.eventId,
                ]
            },
            "gaps": a.gaps.map {
                [
                    "host": $0.host,
                    "after": at($0.afterNanos),
                    "until": at($0.untilNanos),
                    "duration_seconds": Double($0.durationNanos) / 1e9,
                    "last_message_before": $0.lastMessage,
                ]
            },
            "findings": a.findings.map {
                var object: [String: Any] = [
                    "title": $0.title,
                    "detail": $0.detail,
                    "confidence": $0.confidence.rawValue,
                ]
                if let nanos = $0.atNanos { object["at"] = at(nanos) }
                if let host = $0.host { object["host"] = host }
                return object
            },
            "correlations": a.correlations.map {
                [
                    "fault_event_id": $0.faultId,
                    "fault_host": $0.faultHost,
                    "fault_message": $0.faultMessage,
                    "at": at($0.atNanos),
                    "window_seconds": $0.windowSeconds,
                    "elsewhere": $0.elsewhere.map { ExportFormatter.json($0) },
                ]
            },
            "rate_profile": a.rateProfile.map {
                ["at": at($0.startNanos), "events": $0.events, "worst_severity_name": $0.worst.label]
            },
            "flags": [
                "malformed": a.malformed,
                "clock_unset": a.clockUnset,
                "lines_the_nodes_held_back": a.linesHeldBack,
            ],
            "clock_skew": [
                "at_start_seconds": a.skewStartNanos.map { Double($0) / 1e9 } as Any,
                "at_end_seconds": a.skewEndNanos.map { Double($0) / 1e9 } as Any,
                "note": "Receive time minus sender time. A large skew that shrinks fast is a node replaying a boot's backlog, which is correct behaviour.",
            ],
            "confidence_levels": [
                "stated": "the node said so",
                "observed": "the stream shows it directly",
                "suggested": "consistent with the stream, but other explanations fit",
            ],
        ]
    }

    private func badRequest(_ error: Error) -> HTTPResponse {
        .error(400, "Bad Request", (error as? ParsedQuery.Failure)?.message ?? "\(error)")
    }
}
