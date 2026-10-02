import Foundation

enum TranscriptFixture {
    /// One assistant line shaped like Claude Code's transcripts. Defaults = a real Fable 5.1 message (892 373 µ$).
    static func assistant(id: String, model: String = "claude-fable-5-1",
                          timestamp: String = "2026-10-01T15:27:38.176Z",
                          cwd: String = "/Users/dev/code/acme/app", session: String = "s1",
                          input: Int = 2, output: Int = 3475, cacheRead: Int = 25373,
                          cw5m: Int = 0, cw1h: Int = 35613, speed: String = "standard") -> String {
        #"{"type":"assistant","timestamp":"\#(timestamp)","cwd":"\#(cwd)","sessionId":"\#(session)","requestId":"req_\#(id)","message":{"id":"\#(id)","model":"\#(model)","usage":{"input_tokens":\#(input),"cache_creation_input_tokens":\#(cw5m + cw1h),"cache_read_input_tokens":\#(cacheRead),"output_tokens":\#(output),"cache_creation":{"ephemeral_5m_input_tokens":\#(cw5m),"ephemeral_1h_input_tokens":\#(cw1h)},"speed":"\#(speed)"}}}"#
    }

    static let user = #"{"type":"user","timestamp":"2026-10-01T15:27:30.000Z","message":{"role":"user","content":"hi"}}"#

    static func write(_ lines: [String], to url: URL, trailingNewline: Bool = true) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = lines.joined(separator: "\n") + (trailingNewline ? "\n" : "")
        try Data(text.utf8).write(to: url)
    }

    static func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }
}
