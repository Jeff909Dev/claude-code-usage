import Foundation

struct ParsedMessage: Equatable {
    let messageID: String
    let model: String
    let timestamp: Date
    let project: String
    let sessionID: String?
    let usage: TokenUsage
}

enum TranscriptParser {
    static let assistantMarker = Data(#""type":"assistant""#.utf8)

    private struct RawLine: Decodable {
        struct Message: Decodable {
            let id: String?
            let model: String?
            let usage: Usage?
        }
        struct Usage: Decodable {
            struct CacheCreation: Decodable {
                let ephemeral_5m_input_tokens: Int64?
                let ephemeral_1h_input_tokens: Int64?
            }
            let input_tokens: Int64?
            let output_tokens: Int64?
            let cache_read_input_tokens: Int64?
            let cache_creation_input_tokens: Int64?
            let cache_creation: CacheCreation?
            let speed: String?
        }
        let type: String
        let timestamp: String?
        let cwd: String?
        let sessionId: String?
        let message: Message?
    }

    /// Nil for anything that isn't a billable assistant message.
    static func parse(line: Data) -> ParsedMessage? {
        guard line.range(of: assistantMarker) != nil,
              let raw = try? JSONDecoder().decode(RawLine.self, from: line),
              raw.type == "assistant",
              let message = raw.message, let id = message.id, let model = message.model, model != "<synthetic>",
              let usage = message.usage,
              let timestamp = raw.timestamp.flatMap(ISODate.parse) else { return nil }

        let cw5m: Int64
        let cw1h: Int64
        if let detail = usage.cache_creation {
            cw5m = detail.ephemeral_5m_input_tokens ?? 0
            cw1h = detail.ephemeral_1h_input_tokens ?? 0
        } else {
            cw5m = usage.cache_creation_input_tokens ?? 0
            cw1h = 0
        }
        return ParsedMessage(
            messageID: id, model: model, timestamp: timestamp, project: projectName(cwd: raw.cwd),
            sessionID: raw.sessionId,
            usage: TokenUsage(input: usage.input_tokens ?? 0, output: usage.output_tokens ?? 0,
                              cacheRead: usage.cache_read_input_tokens ?? 0, cacheWrite5m: cw5m,
                              cacheWrite1h: cw1h, isFast: usage.speed == "fast"))
    }

    /// Last two path components of the working directory ("acme/app").
    static func projectName(cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return "unknown" }
        let parts = cwd.split(separator: "/").map(String.init)
        return parts.isEmpty ? "unknown" : parts.suffix(2).joined(separator: "/")
    }
}
