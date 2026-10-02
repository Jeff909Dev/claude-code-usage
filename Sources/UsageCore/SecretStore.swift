import Foundation

public protocol SecretStore: Sendable {
    /// Returns nil when the item does not exist.
    func read(service: String, account: String) throws -> Data?
    func write(service: String, account: String, data: Data) throws
    /// Deleting a missing item is not an error.
    func delete(service: String, account: String) throws
}

public enum SecretStoreError: Error, Equatable {
    case commandFailed(operation: String, status: Int32)
    /// The value read back after a write did not match what was written. Never carries values.
    case verificationFailed(operation: String)
    /// A service or account name contains a control character.
    case invalidName
}

public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data]

    public init(_ items: [String: Data] = [:]) { self.items = items }

    public static func key(service: String, account: String) -> String { "\(service)|\(account)" }

    public func read(service: String, account: String) throws -> Data? {
        lock.locked { items[Self.key(service: service, account: account)] }
    }

    public func write(service: String, account: String, data: Data) throws {
        lock.locked { items[Self.key(service: service, account: account)] = data }
    }

    public func delete(service: String, account: String) throws {
        lock.locked { items[Self.key(service: service, account: account)] = nil }
    }

    public var allKeys: [String] { lock.locked { items.keys.sorted() } }
}
