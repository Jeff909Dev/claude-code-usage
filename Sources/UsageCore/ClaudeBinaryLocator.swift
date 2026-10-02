import Foundation

public enum ClaudeBinaryLocator {
    public static func candidates(home: URL, pathEnv: String?) -> [URL] {
        let fromPath = (pathEnv ?? "").split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent("claude") }
        let known = [
            home.appendingPathComponent(".local/bin/claude"),
            home.appendingPathComponent(".claude/local/claude"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude"),
        ]
        var seen = Set<String>()
        return (fromPath + known).filter { seen.insert($0.path).inserted }
    }

    public static func locate(home: URL, pathEnv: String?,
                              isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> URL? {
        candidates(home: home, pathEnv: pathEnv).first { isExecutable($0.path) }
    }
}

public enum ShellEnvironment {
    static let startMarker = "__CU_PATH__:"
    static let endMarker = ":__CU_END__"

    /// PATH as the user's login shell sets it — apps opened from Finder start with a minimal PATH.
    /// Blocks for up to `timeout` seconds, so call it off the main thread. Returns nil when the shell fails or is
    /// too slow (profiles can hang or background helpers).
    public static func loginPATH(shell: String? = nil, timeout: TimeInterval = 3) -> String? {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("cu-path-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let sink = try? FileHandle(forWritingTo: output) else { return nil }
        defer {
            try? sink.close()
            try? FileManager.default.removeItem(at: output)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell ?? ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        // Login scripts may print banners; only what sits between the markers counts.
        process.arguments = ["-lc", "printf '%s' \"\(startMarker)$PATH\(endMarker)\""]
        // A file, not a pipe: a helper that a profile leaves running in the background cannot keep us waiting.
        process.standardOutput = sink
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return nil }
        guard exited.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0,
              let data = try? Data(contentsOf: output) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        guard let start = text.range(of: startMarker),
              let end = text.range(of: endMarker, range: start.upperBound..<text.endIndex) else { return nil }
        let path = String(text[start.upperBound..<end.lowerBound])
        return path.isEmpty ? nil : path
    }
}
