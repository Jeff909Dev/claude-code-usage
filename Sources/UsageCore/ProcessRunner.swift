import Foundation

public protocol ProcessRunner: Sendable {
    /// Runs to completion and returns the exit status. Cancelling the calling task terminates the process
    /// and throws CancellationError.
    func run(executable: URL, arguments: [String], environment: [String: String],
             timeout: TimeInterval) async throws -> Int32
}

public enum ProcessRunnerError: Error, Equatable {
    case timedOut
}

public struct FoundationProcessRunner: ProcessRunner {
    public init() {}

    /// Owns the child. A cancel that arrives before launch is remembered, so the process is never started.
    private final class Box: @unchecked Sendable {
        let process = Process()
        private let lock = NSLock()
        private var cancelled = false

        func launch() throws {
            try lock.locked {
                if cancelled { throw CancellationError() }
                try process.run()
            }
        }

        /// SIGTERM now; SIGKILL after a grace period for children that ignore it.
        func terminate() {
            let pid: pid_t? = lock.locked {
                cancelled = true
                return process.isRunning ? process.processIdentifier : nil
            }
            guard let pid else { return }
            kill(pid, SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [self] in
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }
    }

    public func run(executable: URL, arguments: [String], environment: [String: String],
                    timeout: TimeInterval) async throws -> Int32 {
        let box = Box()
        box.process.executableURL = executable
        box.process.arguments = arguments
        box.process.environment = environment
        box.process.standardInput = FileHandle.nullDevice
        box.process.standardOutput = FileHandle.nullDevice
        box.process.standardError = FileHandle.nullDevice

        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Int32.self) { group in
                group.addTask {
                    try await withCheckedThrowingContinuation { continuation in
                        box.process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                        do { try box.launch() } catch { continuation.resume(throwing: error) }
                    }
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeout))
                    throw ProcessRunnerError.timedOut
                }
                defer {
                    group.cancelAll()
                    box.terminate()
                }
                guard let status = try await group.next() else { throw ProcessRunnerError.timedOut }
                try Task.checkCancellation()
                return status
            }
        } onCancel: {
            box.terminate()
        }
    }
}
