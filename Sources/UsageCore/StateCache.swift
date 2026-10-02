import Foundation

/// Small JSON documents in the app's support folder (state cache, notifier and settings). Writes are atomic.
enum JSONFile {
    /// nil when the file is missing or does not decode.
    static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }
}

/// Last known per-account state on disk, so the menu bar shows numbers instantly at launch.
public enum StateCache {
    public static func load(from url: URL) -> [String: AccountRefreshState] {
        JSONFile.load([String: AccountRefreshState].self, from: url) ?? [:]
    }

    public static func save(_ states: [String: AccountRefreshState], to url: URL) throws {
        try JSONFile.save(states, to: url)
    }
}
