import Foundation
import Testing
@testable import UsageCore

struct TranscriptIndexTests {
    let dir: TempDir
    let projects: URL
    let index: TranscriptIndex

    init() throws {
        dir = try TempDir()
        projects = dir.url.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        index = try TranscriptIndex(databaseURL: dir.file("index.sqlite"), projectsDir: projects, pricing: .builtin)
    }

    func file(_ relative: String) -> URL { projects.appendingPathComponent(relative) }

    @Test func parserReadsUsageAndProject() throws {
        let m = try #require(TranscriptParser.parse(line: Data(TranscriptFixture.assistant(id: "m1").utf8)))
        #expect(m.messageID == "m1")
        #expect(m.project == "acme/app")
        #expect(m.usage == TokenUsage(input: 2, output: 3_475, cacheRead: 25_373, cacheWrite5m: 0, cacheWrite1h: 35_613))
        #expect(TranscriptParser.parse(line: Data(TranscriptFixture.user.utf8)) == nil)
        #expect(TranscriptParser.projectName(cwd: nil) == "unknown")
        #expect(TranscriptParser.projectName(cwd: "/tmp") == "tmp")
    }

    @Test func duplicatesAreCountedOnce() async throws {
        let line = TranscriptFixture.assistant(id: "m1")
        try TranscriptFixture.write([TranscriptFixture.user, line, line, line, line], to: file("p/s1.jsonl"))
        try await index.refresh()
        #expect(try await index.totals() == IndexTotals(messages: 1, costMicros: 892_373))
    }

    @Test func partialLastLineIsCountedOnceWhenCompleted() async throws {
        let first = TranscriptFixture.assistant(id: "m1")
        let second = TranscriptFixture.assistant(id: "m2")
        let half = second.index(second.startIndex, offsetBy: second.count / 2)
        try TranscriptFixture.write([first], to: file("p/s1.jsonl"))
        try TranscriptFixture.append(String(second[..<half]), to: file("p/s1.jsonl"))
        try await index.refresh()
        #expect(try await index.totals().messages == 1)

        try TranscriptFixture.append(String(second[half...]) + "\n", to: file("p/s1.jsonl"))
        try await index.refresh()
        try await index.refresh()
        #expect(try await index.totals() == IndexTotals(messages: 2, costMicros: 2 * 892_373))
    }

    @Test func truncatedFileDoesNotDoubleCount() async throws {
        try TranscriptFixture.write([TranscriptFixture.assistant(id: "m1"), TranscriptFixture.assistant(id: "m2")],
                                    to: file("p/s1.jsonl"))
        try await index.refresh()
        try TranscriptFixture.write([TranscriptFixture.assistant(id: "m1")], to: file("p/s1.jsonl"))
        try await index.refresh()
        #expect(try await index.totals().messages == 2)
    }

    @Test func subagentFilesAreIncluded() async throws {
        try TranscriptFixture.write([TranscriptFixture.assistant(id: "m1")], to: file("p/s1.jsonl"))
        try TranscriptFixture.write([TranscriptFixture.assistant(id: "sub1")], to: file("p/s1/subagents/agent-1.jsonl"))
        let progress = try await index.refresh()
        #expect(progress == IndexProgress(filesDone: 2, filesTotal: 2))
        #expect(try await index.totals().messages == 2)
    }

    @Test func unknownModelIsListedAndCostsZero() async throws {
        try TranscriptFixture.write([TranscriptFixture.assistant(id: "x1", model: "gpt_image_2_5"),
                                     TranscriptFixture.assistant(id: "s1", model: "<synthetic>")],
                                    to: file("p/s1.jsonl"))
        try await index.refresh()
        #expect(try await index.totals() == IndexTotals(messages: 1, costMicros: 0))
        #expect(try await index.unknownModels() == ["gpt_image_2_5"])
    }

    @Test func limitedRefreshReportsPartialProgress() async throws {
        try TranscriptFixture.write([TranscriptFixture.assistant(id: "a")], to: file("p/a.jsonl"))
        try TranscriptFixture.write([TranscriptFixture.assistant(id: "b")], to: file("p/b.jsonl"))
        let first = try await index.refresh(limit: 1)
        #expect(first == IndexProgress(filesDone: 1, filesTotal: 2))
        #expect(first.isComplete == false)
        #expect(try await index.totals().messages == 1)
        let second = try await index.refresh()
        #expect(second.isComplete)
        #expect(try await index.totals().messages == 2)
    }

    @Test func survivesReopenAndReset() async throws {
        try TranscriptFixture.write([TranscriptFixture.assistant(id: "m1")], to: file("p/s1.jsonl"))
        try await index.refresh()
        let reopened = try TranscriptIndex(databaseURL: dir.file("index.sqlite"), projectsDir: projects, pricing: .builtin)
        try await reopened.refresh()
        #expect(try await reopened.totals().messages == 1)
        try await reopened.reset()
        #expect(try await reopened.totals().messages == 0)
        try await reopened.refresh()
        #expect(try await reopened.totals().messages == 1)
    }
}

struct TranscriptIndexRobustnessTests {
    let dir: TempDir
    let projects: URL
    let index: TranscriptIndex

    init() throws {
        dir = try TempDir()
        projects = dir.url.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        index = try TranscriptIndex(databaseURL: dir.file("index.sqlite"), projectsDir: projects, pricing: .builtin)
    }

    func file(_ relative: String) -> URL { projects.appendingPathComponent(relative) }

    @Test func directoryNamedLikeTranscriptIsIgnored() async throws {
        try FileManager.default.createDirectory(at: file("p/x.jsonl"), withIntermediateDirectories: true)
        try TranscriptFixture.write([TranscriptFixture.assistant(id: "m1")], to: file("p/s1.jsonl"))
        let progress = try await index.refresh()
        #expect(progress == IndexProgress(filesDone: 1, filesTotal: 1))
        #expect(try await index.totals().messages == 1)
    }

    @Test func unreadableFileIsSkippedAndOthersIndexed() async throws {
        try TranscriptFixture.write([TranscriptFixture.assistant(id: "a")], to: file("p/a.jsonl"))
        try TranscriptFixture.write([TranscriptFixture.assistant(id: "b")], to: file("p/b.jsonl"))
        try TranscriptFixture.write([TranscriptFixture.assistant(id: "c")], to: file("p/c.jsonl"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file("p/a.jsonl").path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file("p/a.jsonl").path) }
        let progress = try await index.refresh()
        #expect(progress.isComplete)
        #expect(try await index.totals().messages == 2)

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file("p/a.jsonl").path)
        try await index.refresh()
        #expect(try await index.totals().messages == 3)
    }

    @Test func secondWriterWaitsForFirst() throws {
        let url = dir.file("shared.sqlite")
        let second = try SQLiteDatabase(url: url)
        try second.exec("CREATE TABLE t(x INTEGER)")
        let locked = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            do {
                let first = try SQLiteDatabase(url: url)
                try first.exec("BEGIN IMMEDIATE")
                locked.signal()
                Thread.sleep(forTimeInterval: 0.3)
                try first.exec("COMMIT")
            } catch {
                locked.signal()
            }
            finished.signal()
        }
        locked.wait()
        try second.transaction { try second.exec("INSERT INTO t VALUES(1)") }
        finished.wait()
        #expect(try second.prepare("SELECT COUNT(*) FROM t").rows()[0][0].intValue == 1)
    }

    @Test func transactionRollsBackOnFailure() throws {
        let db = try SQLiteDatabase(url: dir.file("tx.sqlite"))
        try db.exec("CREATE TABLE t(x INTEGER); INSERT INTO t VALUES(1)")
        #expect(throws: SQLiteError.self) {
            try db.transaction {
                try db.exec("DELETE FROM t")
                try db.exec("THIS IS NOT SQL")
            }
        }
        #expect(try db.prepare("SELECT COUNT(*) FROM t").rows()[0][0].intValue == 1)
    }

    @Test func intValueNeverTraps() {
        #expect(SQLValue.double(.nan).intValue == 0)
        #expect(SQLValue.double(.infinity).intValue == 0)
        #expect(SQLValue.double(1e30).intValue == Int64.max)
        #expect(SQLValue.double(-1e30).intValue == Int64.min)
        #expect(SQLValue.double(9.223372036854775807e18).intValue == Int64.max)
        #expect(SQLValue.double(12.9).intValue == 12)
    }
}
