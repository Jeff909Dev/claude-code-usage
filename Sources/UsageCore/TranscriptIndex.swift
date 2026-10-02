import Foundation

public struct IndexProgress: Sendable, Equatable {
    public var filesDone: Int
    public var filesTotal: Int
    public var isComplete: Bool { filesDone == filesTotal }

    public init(filesDone: Int, filesTotal: Int) {
        self.filesDone = filesDone
        self.filesTotal = filesTotal
    }
}

public struct IndexTotals: Sendable, Equatable {
    public var messages: Int
    public var costMicros: Int64
}

/// Incremental index of ~/.claude/projects/**/*.jsonl into hourly cost buckets (spec §9).
public actor TranscriptIndex {
    let db: SQLiteDatabase
    private let projectsDir: URL
    private let pricing: PricingTable
    private let selectFile: Statement
    private let upsertFile: Statement
    private let insertSeen: Statement
    private let upsertBucket: Statement
    private let insertSession: Statement
    private let insertUnknown: Statement

    static let schema = """
        CREATE TABLE IF NOT EXISTS files(path TEXT PRIMARY KEY, size INTEGER NOT NULL, mtime REAL NOT NULL,
                                         offset INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS seen(message_id TEXT PRIMARY KEY) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS buckets(hour INTEGER NOT NULL, model TEXT NOT NULL, project TEXT NOT NULL,
            input INTEGER NOT NULL DEFAULT 0, output INTEGER NOT NULL DEFAULT 0, cache_read INTEGER NOT NULL DEFAULT 0,
            cw5m INTEGER NOT NULL DEFAULT 0, cw1h INTEGER NOT NULL DEFAULT 0, cost_micros INTEGER NOT NULL DEFAULT 0,
            messages INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(hour, model, project));
        CREATE TABLE IF NOT EXISTS sessions(hour INTEGER NOT NULL, session_id TEXT NOT NULL,
                                            PRIMARY KEY(hour, session_id)) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS unknown_models(model TEXT PRIMARY KEY) WITHOUT ROWID;
        """

    public init(databaseURL: URL, projectsDir: URL, pricing: PricingTable) throws {
        let db = try SQLiteDatabase(url: databaseURL)
        try db.exec(Self.schema)
        self.db = db
        self.projectsDir = projectsDir
        self.pricing = pricing
        selectFile = try db.prepare("SELECT size, mtime, offset FROM files WHERE path = ?")
        upsertFile = try db.prepare("""
            INSERT INTO files(path, size, mtime, offset) VALUES(?, ?, ?, ?)
            ON CONFLICT(path) DO UPDATE SET size = excluded.size, mtime = excluded.mtime, offset = excluded.offset
            """)
        insertSeen = try db.prepare("INSERT OR IGNORE INTO seen(message_id) VALUES(?)")
        upsertBucket = try db.prepare("""
            INSERT INTO buckets(hour, model, project, input, output, cache_read, cw5m, cw1h, cost_micros, messages)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, 1)
            ON CONFLICT(hour, model, project) DO UPDATE SET
              input = input + excluded.input, output = output + excluded.output,
              cache_read = cache_read + excluded.cache_read, cw5m = cw5m + excluded.cw5m, cw1h = cw1h + excluded.cw1h,
              cost_micros = cost_micros + excluded.cost_micros, messages = messages + 1
            """)
        insertSession = try db.prepare("INSERT OR IGNORE INTO sessions(hour, session_id) VALUES(?, ?)")
        insertUnknown = try db.prepare("INSERT OR IGNORE INTO unknown_models(model) VALUES(?)")
    }

    /// Indexes new bytes of every transcript. With `limit`, stops after that many changed files so callers can
    /// show partial totals during the first (multi-GB) run.
    @discardableResult
    public func refresh(limit: Int? = nil, progress: (@Sendable (IndexProgress) -> Void)? = nil) throws -> IndexProgress {
        let files = Self.transcriptFiles(in: projectsDir)
        var processed = 0
        for (offset, url) in files.enumerated() {
            do {
                if try indexFile(url) { processed += 1 }
            } catch let error as SQLiteError {
                throw error
            } catch {
                // Unreadable or vanished file: skip it (offset untouched) so it can't block the rest.
            }
            let done = IndexProgress(filesDone: offset + 1, filesTotal: files.count)
            if (offset + 1) % 25 == 0 { progress?(done) }
            if let limit, processed >= limit, !done.isComplete {
                progress?(done)
                return done
            }
        }
        let done = IndexProgress(filesDone: files.count, filesTotal: files.count)
        progress?(done)
        return done
    }

    public func totals() throws -> IndexTotals {
        let row = try db.prepare("SELECT COALESCE(SUM(messages), 0), COALESCE(SUM(cost_micros), 0) FROM buckets").rows()[0]
        return IndexTotals(messages: Int(row[0].intValue), costMicros: row[1].intValue)
    }

    public func unknownModels() throws -> [String] {
        try db.prepare("SELECT model FROM unknown_models ORDER BY model").rows().compactMap { $0[0].textValue }
    }

    /// Forgets everything (used by `claude-usage-cli reindex` after editing pricing.json).
    public func reset() throws {
        try db.transaction {
            try db.exec("DELETE FROM files; DELETE FROM seen; DELETE FROM buckets; DELETE FROM sessions; DELETE FROM unknown_models;")
        }
    }

    static func transcriptFiles(in dir: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey],
                                                              options: [.skipsHiddenFiles]) else { return [] }
        var out: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { out.append(url) }
        }
        return out.sorted { $0.path < $1.path }
    }

    /// Returns true when the file had changed and was (re)read.
    private func indexFile(_ url: URL) throws -> Bool {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let stored = try selectFile.rows([.text(url.path)]).first
        if let stored, stored[0].intValue == size, stored[1].doubleValue == mtime { return false }

        var offset = stored?[2].intValue ?? 0
        if offset > size { offset = 0 }   // truncated or rewritten: re-read; `seen` prevents double counting

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))

        try db.transaction {
            var pending = Data()
            var consumed = offset
            while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
                pending.append(chunk)
                var lineStart = pending.startIndex
                while let newline = pending[lineStart...].firstIndex(of: 0x0A) {
                    if let message = TranscriptParser.parse(line: Data(pending[lineStart..<newline])) {
                        try ingest(message)
                    }
                    consumed += Int64(newline - lineStart + 1)
                    lineStart = newline + 1
                }
                pending = Data(pending[lineStart...])   // keep the unfinished last line for later
            }
            try upsertFile.run([.text(url.path), .int(size), .double(mtime), .int(consumed)])
        }
        return true
    }

    private func ingest(_ m: ParsedMessage) throws {
        try insertSeen.run([.text(m.messageID)])
        guard db.changes > 0 else { return }   // already counted (streamed duplicates, resumed sessions)
        let hour = Int64((m.timestamp.timeIntervalSince1970 / 3_600).rounded(.down)) * 3_600
        let cost = CostCalculator.costMicros(m.usage, modelID: m.model, table: pricing)
        if cost == nil { try insertUnknown.run([.text(m.model)]) }
        try upsertBucket.run([.int(hour), .text(m.model), .text(m.project), .int(m.usage.input), .int(m.usage.output),
                              .int(m.usage.cacheRead), .int(m.usage.cacheWrite5m), .int(m.usage.cacheWrite1h),
                              .int(cost ?? 0)])
        if let session = m.sessionID { try insertSession.run([.int(hour), .text(session)]) }
    }
}
