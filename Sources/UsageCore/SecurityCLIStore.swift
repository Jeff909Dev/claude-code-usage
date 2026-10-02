import Foundation

/// Keychain access through /usr/bin/security. Items created this way trust the `security` tool, so Claude Code
/// (which uses the same tool) and this app read them without prompts — even though the app is ad-hoc signed and
/// its code signature changes on every build. Secret values never appear in errors. They are written through
/// `security -i`'s stdin when the command fits its line limit (≤ 4000 B); larger values are passed in argv for the
/// duration of the call, where same-user `ps` can see them.
public struct SecurityCLIStore: SecretStore {
    public let executable: URL
    static let itemNotFound: Int32 = 44

    public init(executable: URL = URL(fileURLWithPath: "/usr/bin/security")) {
        self.executable = executable
    }

    public func read(service: String, account: String) throws -> Data? {
        try Self.validate(service, account)
        let result = try run(["find-generic-password", "-s", service, "-a", account, "-w"], stdin: nil)
        if result.status == Self.itemNotFound { return nil }
        guard result.status == 0 else { throw SecretStoreError.commandFailed(operation: "read", status: result.status) }
        var out = result.stdout
        if out.last == 0x0A { out.removeLast() }
        // `-w` prints hex when the value holds any non-printable byte. A JSON object never looks like hex.
        if out.count % 2 == 0, !out.isEmpty, out.first != UInt8(ascii: "{"), let decoded = Self.hexDecoded(out) {
            return decoded
        }
        return out
    }

    public func write(service: String, account: String, data: Data) throws {
        try Self.validate(service, account)
        let hex = data.map { String(format: "%02x", $0) }.joined()
        // Interactive mode reads the command from stdin, keeping the secret out of `ps`. `security -i` reads each
        // line into a 4096-byte buffer and silently truncates longer ones, so large values use argv instead.
        let command = "add-generic-password -U -s \(Self.quote(service)) -a \(Self.quote(account)) -X \(hex)\n"
        let result: (status: Int32, stdout: Data)
        if command.utf8.count <= Self.interactiveLineLimit {
            result = try run(["-i"], stdin: Data(command.utf8))
        } else {
            result = try run(["add-generic-password", "-U", "-s", service, "-a", account, "-X", hex], stdin: nil)
        }
        guard result.status == 0 else { throw SecretStoreError.commandFailed(operation: "write", status: result.status) }
        // `security -i` may exit 0 even when a command fails, so always verify by reading back.
        guard try read(service: service, account: account) == data else {
            throw SecretStoreError.verificationFailed(operation: "write")
        }
    }

    public func delete(service: String, account: String) throws {
        try Self.validate(service, account)
        let result = try run(["delete-generic-password", "-s", service, "-a", account], stdin: nil)
        guard result.status == 0 || result.status == Self.itemNotFound else {
            throw SecretStoreError.commandFailed(operation: "delete", status: result.status)
        }
    }

    static let interactiveLineLimit = 4000

    /// Control characters would end the line and inject a second command in `security -i` mode.
    static func validate(_ names: String...) throws {
        for name in names where name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            throw SecretStoreError.invalidName
        }
    }

    static func hexDecoded(_ text: Data) -> Data? {
        var bytes = Data(capacity: text.count / 2)
        var high: UInt8?
        for c in text {
            let v: UInt8
            switch c {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): v = c - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): v = c - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): v = c - UInt8(ascii: "A") + 10
            default: return nil
            }
            if let h = high { bytes.append(h << 4 | v); high = nil } else { high = v }
        }
        return bytes
    }

    static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private func run(_ arguments: [String], stdin: Data?) throws -> (status: Int32, stdout: Data) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        let input = Pipe()
        process.standardInput = stdin == nil ? FileHandle.nullDevice : input
        try process.run()
        if let stdin {
            input.fileHandleForWriting.write(stdin)
            try input.fileHandleForWriting.close()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }
}
