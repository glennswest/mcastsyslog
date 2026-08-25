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
            "limit": "how many to return, newest first (default 200, maximum 10000)",
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
                let outcome = try reader.fetch(parsed.query)
                let counted = try reader.countMatching(parsed.query)
                return .json([
                    "events": outcome.events.map { ExportFormatter.json($0) },
                    "returned": outcome.events.count,
                    "matched": counted.count,
                    "matched_exact": counted.exact,
                    "truncated": outcome.truncated,
                    "scanned": outcome.scanned,
                    "elapsed_ms": Double(outcome.elapsedNanos) / 1e6,
                    "query": parsed.describe(),
                ])
            }
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

    private func badRequest(_ error: Error) -> HTTPResponse {
        .error(400, "Bad Request", (error as? ParsedQuery.Failure)?.message ?? "\(error)")
    }
}
