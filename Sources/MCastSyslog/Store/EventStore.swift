import Foundation
import SQLite3

/// How much history to keep. Size and age, whichever comes first.
public struct RetentionPolicy: Equatable, Codable, Sendable {
    public var maxBytes: Int64
    public var maxAgeNanos: Int64

    public static let `default` = RetentionPolicy(
        maxBytes: 2 * 1024 * 1024 * 1024,          // 2 GiB
        maxAgeNanos: 30 * 86_400 * 1_000_000_000   // 30 days
    )

    public init(maxBytes: Int64, maxAgeNanos: Int64) {
        self.maxBytes = maxBytes
        self.maxAgeNanos = maxAgeNanos
    }

    public var maxAgeDays: Int { Int(maxAgeNanos / (86_400 * 1_000_000_000)) }
}

public struct StoreStats: Equatable, Sendable {
    public var events: Int64 = 0
    public var bytes: Int64 = 0
    public var oldestNanos: Int64?
    public var newestNanos: Int64?
    public var hosts: Int = 0
}

public struct RetentionResult: Equatable, Sendable {
    public var deleted: Int64 = 0
    public var reason: String?
}

/// The database. One writer, many readers, WAL between them.
///
/// Every design decision here is the spec's: receive time is the clustering
/// key, filters are ordered index ranges, and retention deletes a whole time
/// range from the front rather than walking rows.
public final class EventStore: @unchecked Sendable {

    public let path: String
    private let writer: SQLiteConnection
    private let writeQueue = DispatchQueue(label: "lo.stormcos.mcastsyslog.store", qos: .utility)
    private var insertStatement: SQLiteStatement?
    private var hostStatement: SQLiteStatement?
    private var tagStatement: SQLiteStatement?

    public static let schemaVersion = 1

    /// `~/Library/Application Support/mcastsyslog/events.sqlite3`
    public static func defaultPath() throws -> String {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("mcastsyslog", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("events.sqlite3").path
    }

    public init(path: String) throws {
        self.path = path
        self.writer = try SQLiteConnection(path: path)
        try configure(writer)
        try migrate()
    }

    private func configure(_ connection: SQLiteConnection) throws {
        // WAL so a reader never blocks the writer, and a long scan in the UI
        // never stalls the stream coming off the wire.
        try connection.execute("PRAGMA journal_mode = WAL")
        // NORMAL, not FULL: an fsync per batch would put the disk in a path that
        // must never be slow, and the node's own file still has every line we
        // could lose on a hard power cut.
        try connection.execute("PRAGMA synchronous = NORMAL")
        // Without this, retention deletes free pages inside the file and the
        // file never gets smaller — a 2 GiB budget that only ever grows.
        try connection.execute("PRAGMA auto_vacuum = INCREMENTAL")
        try connection.execute("PRAGMA temp_store = MEMORY")
        try connection.execute("PRAGMA cache_size = -32000")   // 32 MiB
        try connection.execute("PRAGMA foreign_keys = OFF")
    }

    private func migrate() throws {
        let version = try writer.scalarInt("PRAGMA user_version")
        guard version < Int64(Self.schemaVersion) else { return }

        try writer.execute("""
            CREATE TABLE IF NOT EXISTS events (
                id        INTEGER PRIMARY KEY,
                recv_ns   INTEGER NOT NULL,
                sent_ns   INTEGER,
                host      TEXT    NOT NULL,
                tag       TEXT    NOT NULL,
                severity  INTEGER NOT NULL,
                facility  INTEGER NOT NULL,
                flags     INTEGER NOT NULL,
                repeated  INTEGER,
                source    TEXT    NOT NULL,
                message   TEXT    NOT NULL,
                raw       BLOB,
                event_ns  INTEGER GENERATED ALWAYS AS (COALESCE(sent_ns, recv_ns)) STORED
            );

            CREATE INDEX IF NOT EXISTS events_by_time  ON events (recv_ns, id);
            CREATE INDEX IF NOT EXISTS events_by_event ON events (event_ns, id);
            CREATE INDEX IF NOT EXISTS events_by_host  ON events (host, recv_ns, id);
            CREATE INDEX IF NOT EXISTS events_by_tag   ON events (tag, recv_ns, id);
            CREATE INDEX IF NOT EXISTS events_by_sev   ON events (severity, recv_ns, id);
            CREATE INDEX IF NOT EXISTS events_by_sent  ON events (sent_ns, id);

            CREATE VIRTUAL TABLE IF NOT EXISTS events_fts USING fts5 (
                message, content='events', content_rowid='id', tokenize='unicode61'
            );

            -- External-content FTS: the index carries no copy of the text, so
            -- these triggers are what keep it in step with the table.
            CREATE TRIGGER IF NOT EXISTS events_fts_insert AFTER INSERT ON events BEGIN
                INSERT INTO events_fts(rowid, message) VALUES (new.id, new.message);
            END;
            CREATE TRIGGER IF NOT EXISTS events_fts_delete AFTER DELETE ON events BEGIN
                INSERT INTO events_fts(events_fts, rowid, message) VALUES ('delete', old.id, old.message);
            END;

            -- A directory of what has been heard, so the filter menus and the
            -- fleet list do not have to scan the corpus to populate themselves.
            CREATE TABLE IF NOT EXISTS hosts (
                host     TEXT PRIMARY KEY,
                first_ns INTEGER NOT NULL,
                last_ns  INTEGER NOT NULL,
                source   TEXT
            );
            CREATE TABLE IF NOT EXISTS tags (
                tag      TEXT PRIMARY KEY,
                first_ns INTEGER NOT NULL,
                last_ns  INTEGER NOT NULL
            );

            CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            """)
        try writer.execute("PRAGMA user_version = \(Self.schemaVersion)")
    }

    // MARK: - Writing

    /// Insert a batch in one transaction.
    ///
    /// Synchronous and expected to be called from a background queue — the
    /// receiver's delivery queue. One transaction per datagram would put an
    /// fsync in the receive path; one per batch does not.
    @discardableResult
    public func insert(_ events: [LogEvent]) throws -> Int {
        guard !events.isEmpty else { return 0 }
        return try writeQueue.sync {
            let insert = try insertStatement ?? {
                let s = try writer.prepare("""
                    INSERT INTO events
                        (recv_ns, sent_ns, host, tag, severity, facility, flags, repeated, source, message, raw)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?)
                    """)
                insertStatement = s
                return s
            }()
            let hostUpsert = try hostStatement ?? {
                let s = try writer.prepare("""
                    INSERT INTO hosts (host, first_ns, last_ns, source) VALUES (?,?,?,?)
                    ON CONFLICT(host) DO UPDATE SET
                        last_ns = MAX(last_ns, excluded.last_ns),
                        source  = excluded.source
                    """)
                hostStatement = s
                return s
            }()
            let tagUpsert = try tagStatement ?? {
                let s = try writer.prepare("""
                    INSERT INTO tags (tag, first_ns, last_ns) VALUES (?,?,?)
                    ON CONFLICT(tag) DO UPDATE SET last_ns = MAX(last_ns, excluded.last_ns)
                    """)
                tagStatement = s
                return s
            }()

            return try writer.transaction {
                for event in events {
                    insert.reset()
                    insert.bind(1, event.recvNanos)
                    insert.bind(2, event.sentNanos)
                    insert.bind(3, event.host)
                    insert.bind(4, event.tag)
                    insert.bind(5, Int64(event.severity.rawValue))
                    insert.bind(6, Int64(event.facility))
                    insert.bind(7, Int64(event.flags.rawValue))
                    insert.bind(8, event.repeated.map(Int64.init))
                    insert.bind(9, event.source)
                    insert.bind(10, event.message)
                    insert.bind(11, event.raw)
                    try insert.step()
                }
                // The directory only needs one row per distinct host and tag in
                // the batch, not one per event.
                var seenHosts = Set<String>()
                var seenTags = Set<String>()
                for event in events {
                    if seenHosts.insert(event.host).inserted {
                        hostUpsert.reset()
                        hostUpsert.bind(1, event.host)
                        hostUpsert.bind(2, event.recvNanos)
                        hostUpsert.bind(3, event.recvNanos)
                        hostUpsert.bind(4, event.source)
                        try hostUpsert.step()
                    }
                    if seenTags.insert(event.tag).inserted {
                        tagUpsert.reset()
                        tagUpsert.bind(1, event.tag)
                        tagUpsert.bind(2, event.recvNanos)
                        tagUpsert.bind(3, event.recvNanos)
                        try tagUpsert.step()
                    }
                }
                return events.count
            }
        }
    }

    // MARK: - Retention

    /// Trim to the policy. Age first, then size, and size by deleting the oldest
    /// tenth at a time so a badly over-budget database converges in a few passes
    /// rather than one enormous transaction.
    @discardableResult
    public func enforce(_ policy: RetentionPolicy, now: Int64 = Timestamp.now()) throws -> RetentionResult {
        try writeQueue.sync {
            var result = RetentionResult()

            let ageCutoff = now - policy.maxAgeNanos
            let byAge = try deleteOlderThan(ageCutoff)
            if byAge > 0 {
                result.deleted += byAge
                result.reason = "older than \(policy.maxAgeDays) days"
            }

            var passes = 0
            while try fileBytes() > policy.maxBytes, passes < 12 {
                passes += 1
                // ids are monotonic and only ever deleted from the front, so
                // this finds the oldest tenth without a COUNT over the corpus.
                let lo = try writer.scalarInt("SELECT COALESCE(MIN(id), 0) FROM events")
                let hi = try writer.scalarInt("SELECT COALESCE(MAX(id), 0) FROM events")
                guard hi > lo else { break }
                let cutoffId = lo + max(1, (hi - lo) / 10)
                let deleted = try deleteIdsBelow(cutoffId)
                guard deleted > 0 else { break }
                result.deleted += deleted
                result.reason = "over \(ByteCount.format(policy.maxBytes))"
                try reclaim()
            }

            if result.deleted > 0 { try reclaim() }
            return result
        }
    }

    private func deleteOlderThan(_ cutoffNanos: Int64) throws -> Int64 {
        let stmt = try writer.prepare("DELETE FROM events WHERE recv_ns < ?")
        defer { stmt.finalize() }
        stmt.bind(1, cutoffNanos)
        try writer.transaction {
            try stmt.step()
            try writer.execute("DELETE FROM hosts WHERE last_ns < \(cutoffNanos)")
            try writer.execute("DELETE FROM tags WHERE last_ns < \(cutoffNanos)")
        }
        return Int64(sqlite3_changes(writer.handle))
    }

    private func deleteIdsBelow(_ cutoffId: Int64) throws -> Int64 {
        let stmt = try writer.prepare("DELETE FROM events WHERE id < ?")
        defer { stmt.finalize() }
        stmt.bind(1, cutoffId)
        try writer.transaction { try stmt.step() }
        return Int64(sqlite3_changes(writer.handle))
    }

    /// Hand the freed pages back to the filesystem, a bounded slice at a time so
    /// this never becomes a long stall.
    private func reclaim() throws {
        try writer.execute("PRAGMA incremental_vacuum(2000)")
        try writer.execute("PRAGMA wal_checkpoint(PASSIVE)")
    }

    private func fileBytes() throws -> Int64 {
        let pages = try writer.scalarInt("PRAGMA page_count")
        let size = try writer.scalarInt("PRAGMA page_size")
        return pages * size
    }

    public func stats() throws -> StoreStats {
        try writeQueue.sync {
            var s = StoreStats()
            s.bytes = try fileBytes()
            // ids start at 1, are monotonic, and are only ever deleted from the
            // front, so the range is the count — and MIN/MAX on an INTEGER
            // PRIMARY KEY are O(1), where COUNT(*) is a scan of the whole index.
            let highest = try writer.scalarInt("SELECT COALESCE(MAX(id), 0) FROM events")
            let lowest = try writer.scalarInt("SELECT COALESCE(MIN(id), 0) FROM events")
            s.events = highest == 0 ? 0 : highest - lowest + 1
            s.oldestNanos = try writer.scalarInt("SELECT COALESCE(MIN(recv_ns),0) FROM events")
            s.newestNanos = try writer.scalarInt("SELECT COALESCE(MAX(recv_ns),0) FROM events")
            if s.oldestNanos == 0 { s.oldestNanos = nil }
            if s.newestNanos == 0 { s.newestNanos = nil }
            s.hosts = Int(try writer.scalarInt("SELECT COUNT(*) FROM hosts"))
            return s
        }
    }

    /// Everything, gone. Used by "Clear stored events" in the UI, which asks first.
    public func deleteAll() throws {
        try writeQueue.sync {
            try writer.transaction {
                try writer.execute("DELETE FROM events")
                try writer.execute("DELETE FROM hosts")
                try writer.execute("DELETE FROM tags")
            }
            try writer.execute("PRAGMA incremental_vacuum")
            try writer.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }

    // MARK: - Reading

    /// A reader with its own connection, so a long scan can be interrupted
    /// without touching anything else.
    public func makeReader() throws -> EventReader {
        try EventReader(path: path)
    }
}

/// Byte counts, for the status bar and the retention settings.
public enum ByteCount {
    public static func format(_ bytes: Int64) -> String {
        let units = ["B", "KiB", "MiB", "GiB", "TiB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return unit == 0 ? "\(bytes) B" : String(format: "%.1f %@", value, units[unit])
    }
}
